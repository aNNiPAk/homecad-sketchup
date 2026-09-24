require 'minitest/autorun'

module HomeCAD
  module Runtime
    class BridgeError < StandardError
      attr_reader :category
      def initialize(_code, category, message)
        super(message)
        @category = category
      end
    end
  end
  module Inspection
    def self.check_keys!(params, allowed)
      raise Runtime::BridgeError.new(-32602, 'invalid_request', 'keys') unless (params.keys - allowed).empty?
    end
    def self.invalid!(message) = raise(Runtime::BridgeError.new(-32602, 'invalid_request', message))
  end
end

Point = Struct.new(:x, :y, :z) do
  def distance(other)
    Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
  end
end
module Geom
  Point3d = Point
  Vector3d = Point
end
module Sketchup
  class Camera
    attr_reader :eye, :target
    attr_accessor :perspective
    def initialize(eye, target, _up)
      @eye = eye
      @target = target
    end
  end
end
View = Struct.new(:camera, :vpwidth, :vpheight, :fail_capture, keyword_init: true) do
  def zoom_extents = nil
  def write_image(filename:, **)
    raise 'export failed' if fail_capture

    File.binwrite(filename, "\x89PNG\r\n\x1A\n".b)
    true
  end
end
Model = Struct.new(:active_view)
require File.expand_path('../../sketchup/homecad/core/capture', __dir__)

class CaptureTest < Minitest::Test
  def setup
    camera = Sketchup::Camera.new(Point.new(0, -100, 100), Point.new(0, 0, 0), Point.new(0, 0, 1))
    @view = View.new(camera: camera, vpwidth: 800, vpheight: 600)
    @model = Model.new(@view)
    @original = camera
  end

  def test_success_restores_camera
    result = HomeCAD::Capture.capture(@model, 'view' => 'top', 'max_size' => 400)
    assert_equal @original.eye, @view.camera.eye
    assert_equal 'image/png', result['mime_type']
    assert_equal 400, result['width']
    assert_equal 300, result['height']
    assert result['camera_restored']
  end

  def test_exception_restores_camera
    @view.fail_capture = true
    assert_raises(RuntimeError) { HomeCAD::Capture.capture(@model, 'view' => 'iso') }
    assert_equal @original.eye, @view.camera.eye
  end

  def test_parameter_validation
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Capture.capture(@model, 'max_size' => 5000)
    }.category
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Capture.capture(@model, 'view' => 'perspective')
    }.category
  end
end
