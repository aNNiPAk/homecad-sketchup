require 'sketchup.rb'
require 'extensions.rb'

module HomeCAD
  EXTENSION = SketchupExtension.new('HomeCAD for SketchUp', 'homecad/main')
  EXTENSION.creator = 'HomeCAD contributors'
  EXTENSION.description = 'Local MCP bridge for HomeCAD.'
  EXTENSION.version = '0.1.0'
  Sketchup.register_extension(EXTENSION, true)
end
