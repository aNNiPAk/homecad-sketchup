require 'minitest/autorun'
require File.expand_path('../../sketchup/homecad/core/units', __dir__)

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
  module Targeting
    def self.resolve_one(*) = Object.new
    def self.identity(*) = { 'persistent_id' => 1 }
  end
  module Serializer
    def self.bounds(*) = { 'min' => [254.0, 0.0, 0.0], 'max' => [279.4, 25.4, 25.4] }
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
    attr_reader :eye, :target, :up
    attr_accessor :perspective, :height, :aspect_ratio
    def initialize(eye, target, _up, perspective = true, _fov = 30.0)
      @eye = eye
      @target = target
      @up = _up
      @perspective = perspective
      @height = 100.0
      @aspect_ratio = 0.0
    end
    def perspective? = @perspective
    def fov = 35.0
    def clone = self # SketchUp's Ruby wrapper does not deep-copy its native camera.
    def set(eye, target, up)
      @eye, @target, @up = eye, target, up
    end
  end
end
View = Struct.new(:camera, :vpwidth, :vpheight, :fail_capture, :captured_target, keyword_init: true) do
  def zoom_extents = raise('view.zoom_extents must not be called during capture')
  def refresh = self
  def camera=(value)
    replacement = value.is_a?(Array) ? value[0] : value
    current = self[:camera]
    current.set(replacement.eye, replacement.target, replacement.up)
    current.perspective = replacement.perspective?
    current.height = replacement.height unless replacement.perspective?
    current.aspect_ratio = replacement.aspect_ratio
  end
  def write_image(filename:, **)
    raise 'export failed' if fail_capture

    self.captured_target = camera.target
    File.binwrite(filename, "\x89PNG\r\n\x1A\n".b)
    true
  end
end
Model = Struct.new(:active_view) do
  def bounds
    Struct.new(:min, :max) do
      def empty? = false
    end.new(Point.new(0, 0, 0), Point.new(1, 1, 1))
  end
end
require File.expand_path('../../sketchup/homecad/core/capture', __dir__)

class CaptureTest < Minitest::Test
  def setup
    camera = Sketchup::Camera.new(Point.new(0, -100, 100), Point.new(0, 0, 0), Point.new(0, 0, 1))
    @view = View.new(camera: camera, vpwidth: 800, vpheight: 600)
    @model = Model.new(@view)
    @initial_state = HomeCAD::Capture.camera_state(camera)
  end

  def test_success_restores_camera
    result = HomeCAD::Capture.capture(@model, 'view' => 'top', 'max_size' => 400)
    assert_equal @initial_state, HomeCAD::Capture.camera_state(@view.camera)
    assert_equal 'image/png', result['mime_type']
    assert_equal 400, result['width']
    assert_equal 300, result['height']
    assert result['camera_restored']
    assert_equal result['camera_before'], result['camera_after']
  end

  def test_exception_restores_camera
    @view.fail_capture = true
    assert_raises(RuntimeError) { HomeCAD::Capture.capture(@model, 'view' => 'iso') }
    assert_equal @initial_state, HomeCAD::Capture.camera_state(@view.camera)
  end

  def test_nested_target_centers_world_bounds_and_restores_camera
    result = HomeCAD::Capture.capture(@model, 'view' => 'top', 'target' => { 'persistent_id' => 1 })
    assert_in_delta 10.5, @view.captured_target.x, 0.0001
    assert_equal @initial_state, HomeCAD::Capture.camera_state(@view.camera)
    assert result['camera_restored']
  end

  def test_zoom_extents_frames_model_without_view_zoom_and_restores_camera
    result = HomeCAD::Capture.capture(@model, 'view' => 'iso', 'zoom_extents' => true)
    assert result['camera_restored']
    assert_equal @initial_state, HomeCAD::Capture.camera_state(@view.camera)
    assert_in_delta 0.5, @view.captured_target.x, 0.0001
  end

  def test_parameter_validation
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Capture.capture(@model, 'max_size' => 5000)
    }.category
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Capture.capture(@model, 'view' => 'perspective')
    }.category
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Capture.capture(@model, 'target' => { 'persistent_id' => 1 }, 'zoom_extents' => true)
    }.category
  end
end
