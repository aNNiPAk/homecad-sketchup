require 'json'
require 'socket'

module HomeCAD
  VERSION = '0.2.1'
  PROTOCOL_VERSION = 1
end

Sketchup.require 'homecad/runtime/config'
Sketchup.require 'homecad/runtime/errors'
Sketchup.require 'homecad/runtime/logging'
Sketchup.require 'homecad/runtime/framing'
Sketchup.require 'homecad/runtime/operation'
Sketchup.require 'homecad/core/units'
Sketchup.require 'homecad/core/scene'
Sketchup.require 'homecad/core/targeting'
Sketchup.require 'homecad/core/serializer'
Sketchup.require 'homecad/core/inspection'
Sketchup.require 'homecad/core/measurement'
Sketchup.require 'homecad/core/capture'
Sketchup.require 'homecad/runtime/dispatcher'
Sketchup.require 'homecad/runtime/server'

module HomeCAD
  def self.start
    @server ||= Runtime::Server.new
    @server.start
  end

  def self.stop
    @server&.stop
  end

  unless file_loaded?(__FILE__)
    start
    file_loaded(__FILE__)
  end
end
