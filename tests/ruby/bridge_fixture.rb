# Minimal SketchUp stand-in used only by the cross-language TCP test.
require 'json'
require 'socket'

module UI
  def self.start_timer(*) = 1
  def self.stop_timer(*) = nil
end

FixturePoint = Struct.new(:x, :y, :z) do
  def distance(other) = Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
  def transform(*) = self
end
module Geom
  Point3d = FixturePoint
  Vector3d = FixturePoint
end
FixtureBounds = Struct.new(:origin) do
  def empty? = false
  def min = FixturePoint.new(origin, 0, 0)
  def max = FixturePoint.new(origin + 1, 1, 1)
  def corner(index)
    FixturePoint.new(origin + (index & 1), (index >> 1) & 1, (index >> 2) & 1)
  end
end
FixtureEntity = Struct.new(:persistent_id, :entityID, :typename, :name, :bounds, :metadata, keyword_init: true) do
  def attribute_dictionary(*) = metadata
  def valid? = true
  def hidden? = false
  def parent = Sketchup.active_model
end
FixtureView = Struct.new(:camera, keyword_init: true) do
  def vpwidth = 800
  def vpheight = 600
  def zoom_extents = self
  def zoom(*) = self
  def refresh = self
  def camera=(value)
    self[:camera] = value.is_a?(Array) ? value[0] : value
  end
  def write_image(filename:, **)
    File.binwrite(filename, "\x89PNG\r\n\x1A\nfixture".b)
    true
  end
end

module Sketchup
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
  Model = Struct.new(:name, :title, :path, :guid, :entities, :active_entities,
                     :selection, :active_view, keyword_init: true) do
    def modified? = false
    def bounds = FixtureBounds.new(0)
    def find_entity_by_persistent_id(id) = entities.find { |entity| entity.persistent_id == id }
    def find_entity_by_id(id) = entities.find { |entity| entity.entityID == id }
  end

  def self.version = '2026.0-test'
  def self.active_model
    @active_model ||= begin
      chair = FixtureEntity.new(persistent_id: 11, entityID: 101, typename: 'Group',
                                name: 'Known Chair', bounds: FixtureBounds.new(0),
                                metadata: { 'homecad_id' => 'ambiguous-fixture' })
      table = FixtureEntity.new(persistent_id: 12, entityID: 102, typename: 'Group',
                                name: 'Table', bounds: FixtureBounds.new(3),
                                metadata: { 'homecad_id' => 'ambiguous-fixture' })
      camera = Camera.new(FixturePoint.new(0, -100, 100), FixturePoint.new(0, 0, 0),
                          FixturePoint.new(0, 0, 1))
      Model.new(name: 'Fixture Apartment', title: 'fixture', path: 'fixture.skp',
                guid: 'fixture-guid', entities: [chair, table], active_entities: [chair],
                selection: [chair], active_view: FixtureView.new(camera: camera))
    end
  end
  def self.send_action(*) = true
end

module HomeCAD
  VERSION = '0.3.0'
  PROTOCOL_VERSION = 1
end

root = File.expand_path('../../sketchup/homecad', __dir__)
%w[config errors logging framing].each do |name|
  require File.join(root, 'runtime', name)
end
%w[units scene targeting serializer inspection measurement capture].each do |name|
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
