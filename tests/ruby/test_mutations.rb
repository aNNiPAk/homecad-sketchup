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
    def dot(other) = x * other.x + y * other.y + z * other.z
    def parallel?(other) = cross(other).length < 1e-9
  end
  class Transformation
    attr_reader :offset, :xaxis, :yaxis, :zaxis
    def initialize(offset = [0, 0, 0], axes = nil)
      @offset = offset
      @xaxis, @yaxis, @zaxis = axes || [Vector3d.new(1, 0, 0), Vector3d.new(0, 1, 0), Vector3d.new(0, 0, 1)]
    end
    def self.translation(vector) = new([vector.x, vector.y, vector.z])
    def self.rotation(_point, _axis, angle)
      cosine, sine = Math.cos(angle), Math.sin(angle)
      new([0, 0, 0], [Vector3d.new(cosine, sine, 0), Vector3d.new(-sine, cosine, 0), Vector3d.new(0, 0, 1)])
    end
    def self.scaling(_point, x, y, z) = new([0, 0, 0], [Vector3d.new(x, 0, 0), Vector3d.new(0, y, 0), Vector3d.new(0, 0, z)])
    def *(other)
      if other.is_a?(Vector3d)
        return Vector3d.new(xaxis.x * other.x + yaxis.x * other.y + zaxis.x * other.z,
                            xaxis.y * other.x + yaxis.y * other.y + zaxis.y * other.z,
                            xaxis.z * other.x + yaxis.z * other.y + zaxis.z * other.z)
      end
      if other.is_a?(Point3d)
        Point3d.new(xaxis.x * other.x + yaxis.x * other.y + zaxis.x * other.z + offset[0],
                    xaxis.y * other.x + yaxis.y * other.y + zaxis.y * other.z + offset[1],
                    xaxis.z * other.x + yaxis.z * other.y + zaxis.z * other.z + offset[2])
      else
        origin = self * Point3d.new(*other.offset)
        Transformation.new([origin.x, origin.y, origin.z],
          [self * other.xaxis, self * other.yaxis, self * other.zaxis])
      end
    end
    def inverse
      inverse_axes = [
        Vector3d.new(xaxis.x, yaxis.x, zaxis.x),
        Vector3d.new(xaxis.y, yaxis.y, zaxis.y),
        Vector3d.new(xaxis.z, yaxis.z, zaxis.z)
      ]
      inverse_offset = inverse_axes.map { |axis| -(axis.x * offset[0] + axis.y * offset[1] + axis.z * offset[2]) }
      Transformation.new(inverse_offset, inverse_axes)
    end
    def to_a = [xaxis.x, yaxis.x, zaxis.x, 0, xaxis.y, yaxis.y, zaxis.y, 0,
                xaxis.z, yaxis.z, zaxis.z, 0, *offset, 1]
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
  def erase!
    @valid = false
    collection = parent.respond_to?(:entities) ? parent.entities : parent
    collection.delete(self) if collection.respond_to?(:delete)
    true
  end
  def attribute_dictionary(name, _create = false) = @attributes[name]
  def set_attribute(dictionary, key, value) = (@attributes[dictionary] ||= {})[key] = value
  def points = @points
  def add_points(points) = @points.concat(points)
  def replace_points(points) = (@points = points)
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
    def split(other) = MutationBoolean.split(self, other)
  end
  class ComponentInstance < Group; end
  class Face < MutationEntity
    attr_accessor :fail_follow, :retain_path
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
    def followme(edges)
      return false if edges.empty?
      parent.add_points(edges.flat_map(&:points))
      edges.each { |edge| edge.faces = [self] } if retain_path
      !fail_follow
    end
  end
  class Edge < MutationEntity
    attr_accessor :faces
    def initialize(id, model, parent, points)
      super(id, 'Edge', model, parent, points)
    end
    def faces = @faces || []
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
      @snapshot = entities.dup
      @nested_snapshot = entities.to_h { |group| [group, [group.entities.dup, group.points.dup]] }
      true
    end
    def commit_operation
      @events << [:commit]
      true
    end
    def abort_operation
      @events << [:abort]
      entities.replace(@snapshot)
      @nested_snapshot.each do |group, (children, points)|
        group.entities.replace(children)
        group.replace_points(points)
      end
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
    attr_accessor :receiver, :argument, :fail_split
    def make_result(model)
      self.receiver ||= nil
      model.entities.add_group.tap { |group| group.add_points([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 1)]) }
    end

    # Match documented SketchUp ordering: [other - self, self - other, intersection].
    def split(target, tool)
      return nil if fail_split
      target_bounds, tool_bounds = target.bounds, tool.bounds
      target_min, target_max = target_bounds.min, target_bounds.max
      tool_min, tool_max = tool_bounds.min, tool_bounds.max
      diff2 = box(target.model, [target_max.x, target_min.y, target_min.z], [tool_max.x, target_max.y, target_max.z])
      diff1 = box(target.model, [target_min.x, target_min.y, target_min.z], [tool_min.x, target_max.y, target_max.z])
      intersection = box(target.model, [tool_min.x, target_min.y, target_min.z], [target_max.x, target_max.y, target_max.z])
      target.erase!
      tool.erase!
      self.receiver = [diff2, diff1, intersection]
    end

    def box(model, minimum, maximum)
      group = model.entities.add_group
      group.add_points([Geom::Point3d.new(*minimum), Geom::Point3d.new(*maximum)])
      group
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
    MutationBoolean.receiver = nil
    MutationBoolean.fail_split = false
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

  def test_push_pull_rejects_uniform_nonuniform_shear_and_mirror_before_operation
    resolve_to(@face_entry)
    transforms = [
      Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), 2, 2, 2),
      Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), 2, 3, 4),
      Geom::Transformation.new([0, 0, 0], [Geom::Vector3d.new(1, 0, 0),
        Geom::Vector3d.new(0.5, 1, 0), Geom::Vector3d.new(0, 0, 1)]),
      Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), -1, 1, 1)
    ]
    transforms.each do |transformation|
      @group.transformation = transformation
      error = assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Mutations.push_pull(@model,
          'target' => { 'persistent_id' => @face.persistent_id }, 'distance_mm' => 25.4)
      end
      assert_equal 'constraint_violation', error.category
      assert_empty @model.events
      assert_equal 1, HomeCAD::Metadata.read(@group)['revision']
    end
  end

  def test_push_pull_allows_rigid_translation_and_rotation
    transforms = [
      Geom::Transformation.translation(Geom::Vector3d.new(10, 20, 30)),
      Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0),
        Geom::Vector3d.new(0, 0, 1), Math::PI / 3)
    ]
    transforms.each_with_index do |transformation, index|
      @group.transformation = transformation
      resolve_to(@face_entry)
      result = HomeCAD::Mutations.push_pull(@model,
        'target' => { 'persistent_id' => @face.persistent_id }, 'distance_mm' => 25.4)
      assert_equal index + 2, result['revision']
      assert_equal %i[start commit], @model.events.map(&:first)
      @model.events.clear
    end
  end

  def test_follow_me_removes_unreferenced_helper_path_edges
    resolve_to(@face_entry)
    result = HomeCAD::Mutations.follow_me(@model,
      'target' => { 'persistent_id' => @face.persistent_id },
      'path_points_mm' => [[0, 0, 0], [0, 0, 25.4]])
    assert_equal 'success', result['status']
    assert_equal 2, result['revision']
    assert_equal %i[start commit], @model.events.map(&:first)
    assert_empty @group.entities.grep(Sketchup::Edge)
    assert_empty result['warnings']
  end

  def test_follow_me_keeps_path_edges_shared_with_swept_faces_and_warns
    resolve_to(@face_entry)
    @face.retain_path = true
    result = HomeCAD::Mutations.follow_me(@model,
      'target' => { 'persistent_id' => @face.persistent_id },
      'path_points_mm' => [[0, 0, 0], [0, 0, 25.4]])
    assert_equal 2, result['revision']
    assert_equal 1, @group.entities.grep(Sketchup::Edge).length
    assert_match(/retained as geometry boundaries/, result['warnings'].first)
  end

  def test_follow_me_failure_aborts_path_and_partial_sweep_without_revision
    resolve_to(@face_entry)
    @face.fail_follow = true
    points_before = @group.points.dup
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Mutations.follow_me(@model,
        'target' => { 'persistent_id' => @face.persistent_id },
        'path_points_mm' => [[0, 0, 0], [0, 0, 25.4], [25.4, 0, 25.4]])
    end
    assert_equal 'geometry_error', error.category
    assert_equal %i[start abort], @model.events.map(&:first)
    assert_equal points_before, @group.points
    assert_empty @group.entities.grep(Sketchup::Edge)
    assert_equal 1, HomeCAD::Metadata.read(@group)['revision']
  end

  def test_follow_me_rejects_duplicate_path_points_before_operation
    resolve_to(@face_entry)
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Mutations.follow_me(@model,
        'target' => { 'persistent_id' => @face.persistent_id },
        'path_points_mm' => [[0, 0, 0], [0.001, 0, 0]])
    end
    assert_equal 'invalid_request', error.category
    assert_empty @model.events
  end

  def test_boolean_difference_selects_target_minus_tool_from_documented_split_order
    target = @group
    target.replace_points([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(600.0 / 25.4, 400.0 / 25.4, 300.0 / 25.4)])
    tool = @model.entities.add_group
    HomeCAD::Metadata.create!(tool, type: 'primitive.box')
    tool.add_points([Geom::Point3d.new(300.0 / 25.4, 0, 0), Geom::Point3d.new(800.0 / 25.4, 400.0 / 25.4, 300.0 / 25.4)])
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
    boolean_result = result['created'][0]
    assert_in_delta 300, boolean_result.dig('bbox_dimensions_mm', 'width'), 1e-6
    assert_in_delta 0, boolean_result.dig('bbox_mm', 'min', 0), 1e-6
    assert_equal 3, @model.entities.length, 'only the two sources and selected result remain'
    assert_equal 3, MutationBoolean.receiver.length
  end

  def test_union_and_intersect_remain_available_and_boolean_failure_aborts
    target_entry = @group_entry
    tool = @model.entities.add_group
    HomeCAD::Metadata.create!(tool, type: 'primitive.box')
    tool.add_points([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(10, 10, 10)])
    tool_entry = HomeCAD::Scene::Entry.new(entity: tool, parent: nil,
      path: [tool.persistent_id], transform: nil)
    HomeCAD::Targeting.define_singleton_method(:resolve_one) do |_model, selector|
      selector['homecad_id'] == HomeCAD::Metadata.read(@group)['homecad_id'] ? target_entry : tool_entry
    end
    %w[union intersect].each do |operation|
      result = HomeCAD::Mutations.boolean_operation(@model,
        'target' => { 'homecad_id' => HomeCAD::Metadata.read(@group)['homecad_id'] },
        'tool' => { 'persistent_id' => tool.persistent_id }, 'operation' => operation)
      assert_equal 'primitive.boolean', result.dig('created', 0, 'metadata', 'type')
    end
    assert @group.valid?
    assert tool.valid?

    before = @model.entities.dup
    MutationBoolean.fail_split = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Mutations.boolean_operation(@model,
        'target' => { 'homecad_id' => HomeCAD::Metadata.read(@group)['homecad_id'] },
        'tool' => { 'persistent_id' => tool.persistent_id }, 'operation' => 'difference')
    end
    assert_equal 'geometry_error', error.category
    assert_equal %i[start commit start commit start abort], @model.events.map(&:first)
    assert_equal before, @model.entities
    assert @group.valid?
    assert tool.valid?
  end
end
