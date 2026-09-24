# Minimal SketchUp stand-in used only by the cross-language TCP test.
require 'json'
require 'socket'

module UI
  def self.start_timer(*) = 1
  def self.stop_timer(*) = nil
end

module Sketchup
  Model = Struct.new(:name, :title, :path, :guid, :entities, :active_entities,
                     :selection, keyword_init: true) do
    def modified? = false
  end

  def self.version = '2026.0-test'
  def self.active_model
    @active_model ||= Model.new(name: 'Fixture Apartment', title: 'fixture', path: 'fixture.skp',
                                guid: 'fixture-guid', entities: [1, 2], active_entities: [1],
                                selection: [])
  end
end

module HomeCAD
  VERSION = '0.1.0'
  PROTOCOL_VERSION = 1
end

root = File.expand_path('../../sketchup/homecad', __dir__)
%w[config errors logging framing].each do |name|
  require File.join(root, 'runtime', name)
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
