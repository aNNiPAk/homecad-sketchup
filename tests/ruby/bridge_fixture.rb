# Minimal SketchUp stand-in used only by the cross-language TCP test.
require 'json'
require 'socket'

module UI
  def self.start_timer(*) = 1
  def self.stop_timer(*) = nil
end

class FixturePoint
  attr_reader :x, :y, :z
  def initialize(x, y, z) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
  def distance(other) = Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
  def transform(transformation) = transformation * self
  def offset(vector, distance)
    FixturePoint.new(x + vector.x * distance, y + vector.y * distance, z + vector.z * distance)
  end
end

class FixtureVector < FixturePoint
  def length = Math.sqrt(x * x + y * y + z * z)
  def length=(value)
    factor = value / length
    @x *= factor
    @y *= factor
    @z *= factor
  end
  def cross(other) = FixtureVector.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
  def parallel?(other) = cross(other).length < 1e-9
end

module Geom
  Point3d = FixturePoint
  Vector3d = FixtureVector
  class Transformation
    attr_reader :translation
    def initialize(x = 0, y = 0, z = 0, axes = nil)
      @translation = [x.to_f, y.to_f, z.to_f]
      @axes = axes || [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    end
    def self.axes(origin, xaxis, yaxis, zaxis)
      new(origin.x, origin.y, origin.z, [[xaxis.x, xaxis.y, xaxis.z],
        [yaxis.x, yaxis.y, yaxis.z], [zaxis.x, zaxis.y, zaxis.z]])
    end
    def self.translation(vector) = new(vector.x, vector.y, vector.z)
    def self.rotation(*) = new
    def self.scaling(*) = new
    def *(other)
      if other.is_a?(FixturePoint)
        FixturePoint.new(translation[0] + @axes[0][0] * other.x + @axes[1][0] * other.y + @axes[2][0] * other.z,
                         translation[1] + @axes[0][1] * other.x + @axes[1][1] * other.y + @axes[2][1] * other.z,
                         translation[2] + @axes[0][2] * other.x + @axes[1][2] * other.y + @axes[2][2] * other.z)
      elsif other.is_a?(Transformation)
        Transformation.new(translation[0] + other.translation[0],
                           translation[1] + other.translation[1],
                           translation[2] + other.translation[2])
      else
        raise TypeError, 'unsupported fixture transformation operand'
      end
    end
    def inverse = Transformation.new(*translation.map { |value| -value })
    def to_a
      [@axes[0][0], @axes[0][1], @axes[0][2], 0,
       @axes[1][0], @axes[1][1], @axes[1][2], 0,
       @axes[2][0], @axes[2][1], @axes[2][2], 0, *translation, 1]
    end
  end
end

class FixtureBounds
  attr_reader :min, :max
  def initialize(origin_or_min, max = nil)
    if max
      @min, @max = origin_or_min, max
    else
      origin = origin_or_min.to_f
      @min = FixturePoint.new(origin, 0, 0)
      @max = FixturePoint.new(origin + 1, 1, 1)
    end
  end
  def empty? = false
  def corner(index)
    FixturePoint.new((index & 1).zero? ? min.x : max.x,
                     (index & 2).zero? ? min.y : max.y,
                     (index & 4).zero? ? min.z : max.z)
  end
end

class FixtureEntities < Array
  attr_reader :owner
  def initialize(owner)
    @owner = owner
    super()
  end
  def model = owner.respond_to?(:model) ? owner.model : owner
  def add_group
    group = Sketchup::Group.new(model.next_id, model, self)
    self << group
    group
  end
  def add_instance(definition, transformation)
    group = Sketchup::ComponentInstance.new(model.next_id, model, self)
    group.definition = definition
    group.transformation = transformation
    self << group
    group
  end
  def add_face(points)
    return nil if points.length < 3
    face = Sketchup::Face.new(model.next_id, model, owner, points)
    self << face
    face
  end
  def clear!
    clear
    owner.reset_points if owner.respond_to?(:reset_points)
    true
  end
  def erase_entities(*entities)
    entities.each { |entity| delete(entity); entity.erase! if entity.respond_to?(:erase!) }
    true
  end
  def add_line(first, last)
    edge = Sketchup::Edge.new(model.next_id, model, owner, [first, last])
    self << edge
    edge
  end
  def add_circle(center, _normal, radius, segments)
    first = FixturePoint.new(center.x - radius, center.y - radius, center.z)
    last = FixturePoint.new(center.x + radius, center.y + radius, center.z)
    owner.add_points([first, last])
    Array.new(segments) { add_line(center, center) }
  end
  def add_arc(center, _x_axis, _normal, radius, start_angle, end_angle, segments)
    owner.last_arc = [start_angle, end_angle, segments]
    add_circle(center, nil, radius, segments)
  end
end

class FixtureEntity
  attr_reader :persistent_id, :entityID, :name, :model, :parent
  attr_accessor :name
  def initialize(persistent_id:, typename:, name: '', model:, parent:, bounds: nil)
    @persistent_id = @entityID = persistent_id
    @typename, @name, @model, @parent, @bounds = typename, name, model, parent, bounds
    @metadata = {}
    @valid = true
    @locked = false
  end
  def typename = @typename
  def bounds = @bounds
  def set_bounds(bounds) = (@bounds = bounds)
  def attribute_dictionary(name, _create = false) = @metadata[name]
  def set_attribute(dictionary, key, value) = (@metadata[dictionary] ||= {})[key] = value
  def valid? = @valid
  def deleted? = !@valid
  def locked? = @locked
  def locked=(value)
    @locked = value
  end
  def hidden? = false
  def layer = nil
  def material = nil
  def erase! = (@valid = false)
end

class FixtureFace < FixtureEntity
  attr_reader :points, :group
  def initialize(id, model, group, points)
    @group, @points = group, points
    super(persistent_id: id, typename: 'Face', model: model, parent: group)
    group.add_points(points)
  end
  def pushpull(distance)
    group.add_points(points.map { |point| FixturePoint.new(point.x, point.y, point.z + distance) })
    nil
  end
  def followme(edges) = !edges.empty?
end

class FixtureEdge < FixtureEntity
  def initialize(id, model, group, points)
    super(persistent_id: id, typename: 'Edge', model: model, parent: group)
    group.add_points(points)
  end
end

class FixtureDefinition
  attr_reader :group
  def initialize(group) = (@group = group)
  def manifold? = true
  def instances = [group]
end

class FixtureGroup < FixtureEntity
  attr_reader :entities, :model
  attr_accessor :transformation, :last_arc, :definition
  def initialize(id, model, parent_collection)
    super(persistent_id: id, typename: 'Group', model: model, parent: parent_collection)
    @points = []
    @entities = FixtureEntities.new(self)
    @transformation = Geom::Transformation.new
  end
  def add_points(points) = @points.concat(points)
  def reset_points = @points.clear
  def fail_face = false
  def bounds
    return nil if @points.empty?
    transformed = @points.map { |point| transformation * point }
    min = FixturePoint.new(*3.times.map { |index| transformed.map { |point| [point.x, point.y, point.z][index] }.min })
    max = FixturePoint.new(*3.times.map { |index| transformed.map { |point| [point.x, point.y, point.z][index] }.max })
    FixtureBounds.new(min, max)
  end
  def definition = @definition || FixtureDefinition.new(self)
  def transformation=(value)
    @transformation = value
  end
  def transform!(value)
    @transformation = value * @transformation
    true
  end
  def parent
    return model if super.is_a?(FixtureEntities) && super.owner.equal?(model)
    super
  end
end

class FixtureView
  attr_reader :camera
  def initialize(camera:) = (@camera = camera)
  def vpwidth = 800
  def vpheight = 600
  def zoom_extents = self
  def zoom(*) = self
  def refresh = self
  def camera=(value)
    @camera = value.is_a?(Array) ? value[0] : value
  end
  def write_image(filename:, **)
    File.binwrite(filename, "\x89PNG\r\n\x1A\nfixture".b)
    true
  end
end

module Sketchup
  class Group < FixtureGroup; end
  class ComponentInstance < FixtureGroup; end
  class Face < FixtureFace; end
  class Edge < FixtureEdge; end
  class Camera
    attr_reader :eye, :target, :up
    attr_accessor :perspective, :height, :aspect_ratio
    def initialize(eye, target, up, perspective = true, _fov = 30.0)
      @eye, @target, @up = eye, target, up
      @perspective = perspective
      @aspect_ratio = 0.0
    end
    def perspective? = @perspective
    def fov = 35.0
    def fov_is_height? = true
    def height = @height || 100.0
    def set(eye, target, up)
      @eye, @target, @up = eye, target, up
    end
  end
  class Model
    attr_reader :name, :title, :path, :guid, :entities, :active_entities, :selection, :active_view
    def initialize(camera)
      @name, @title, @path, @guid = 'Fixture Apartment', 'fixture', 'fixture.skp', 'fixture-guid'
      @entities = FixtureEntities.new(self)
      @active_entities = @entities
      @selection = []
      @active_view = FixtureView.new(camera: camera)
      @next_id = 100
      @entities << FixtureEntity.new(persistent_id: 11, typename: 'Group', name: 'Known Chair',
                                     model: self, parent: @entities, bounds: FixtureBounds.new(0))
      @entities << FixtureEntity.new(persistent_id: 12, typename: 'Group', name: 'Table',
                                     model: self, parent: @entities, bounds: FixtureBounds.new(3))
      @entities.each { |entity| entity.set_attribute('HomeCAD', 'homecad_id', 'ambiguous-fixture') }
      @selection << @entities.first
    end
    def next_id
      @next_id += 1
    end
    def modified? = false
    def bounds = FixtureBounds.new(0)
    def find_entity_by_persistent_id(id) = find_recursive(entities, :persistent_id, id)
    def find_entity_by_id(id) = find_recursive(entities, :entityID, id)
    def find_recursive(collection, key, value)
      collection.each do |entity|
        return entity if entity.public_send(key) == value
        if entity.respond_to?(:entities)
          found = find_recursive(entity.entities, key, value)
          return found if found
        end
      end
      nil
    end
    def start_operation(*) = true
    def commit_operation = true
    def abort_operation = true
  end

  def self.version = '2026.0-test'
  def self.active_model
    @active_model ||= Model.new(Camera.new(FixturePoint.new(0, -100, 100), FixturePoint.new(0, 0, 0),
                                           FixturePoint.new(0, 0, 1)))
  end
  def self.send_action(*) = true
end

module HomeCAD
  VERSION = '0.3.0'
  PROTOCOL_VERSION = 1
end

root = File.expand_path('../../sketchup/homecad', __dir__)
%w[config errors logging framing operation].each do |name|
  require File.join(root, 'runtime', name)
end
%w[units metadata scene targeting serializer mutation inspection measurement capture geometry primitives mutations architecture].each do |name|
  require File.join(root, 'core', name)
end
require File.join(root, 'runtime', 'dispatcher')
require File.join(root, 'runtime', 'server')

server = HomeCAD::Runtime::Server.new(port: 0)
server.start
puts server.instance_variable_get(:@listener).addr[1]
$stdout.flush
loop do
  server.tick
  sleep 0.005
end
