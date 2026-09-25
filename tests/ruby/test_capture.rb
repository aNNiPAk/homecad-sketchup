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
    attr_accessor :perspective, :height, :aspect_ratio, :fov_is_height
    def initialize(eye, target, _up, perspective = true, fov = 30.0)
      @eye = eye
      @target = target
      @up = _up
      @perspective = perspective
      @fov = fov
      @height = 100.0
      @aspect_ratio = 0.0
      @fov_is_height = true
    end
    def perspective? = @perspective
    def fov = @fov
    def fov=(value)
      @fov = value
    end
    def fov_is_height? = @fov_is_height
    def is_2d? = @two_point
    def two_point=(value)
      @two_point = value
    end
    def clone = self # SketchUp's Ruby wrapper does not deep-copy its native camera.
    def set(eye, target, up)
      @eye, @target, @up = eye, target, up
    end
  end
end
View = Struct.new(:camera, :vpwidth, :vpheight, :fail_capture, :captured_target,
                  :camera_assignments, keyword_init: true) do
  def zoom_extents = raise('view.zoom_extents must not be called during capture')
  def refresh = self
  def camera=(value)
    replacement = value.is_a?(Array) ? value[0] : value
    current = self[:camera]
    current.set(replacement.eye, replacement.target, replacement.up)
    current.perspective = replacement.perspective?
    current.fov = replacement.fov if replacement.perspective?
    current.fov_is_height = replacement.fov_is_height? if replacement.perspective?
    current.height = replacement.height unless replacement.perspective?
    current.aspect_ratio = replacement.aspect_ratio
    self[:camera_assignments] = (camera_assignments || 0) + 1
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

  def test_current_capture_does_not_assign_a_camera_and_reports_fov_axis
    result = HomeCAD::Capture.capture(@model, 'view' => 'current')
    assert_equal 0, @view.camera_assignments || 0
    assert_equal true, result['camera_before']['fov_is_height']
    assert_equal result['camera_before'], result['camera_after']
    assert result['camera_restored']
  end

  def test_parallel_projection_restores_height_and_camera_state
    @view.camera.perspective = false
    @view.camera.height = 42.0
    @initial_state = HomeCAD::Capture.camera_state(@view.camera)
    result = HomeCAD::Capture.capture(@model, 'view' => 'top')
    assert_nil result['camera_before']['fov_is_height']
    assert_equal 42.0, @view.camera.height
    assert_equal @initial_state, HomeCAD::Capture.camera_state(@view.camera)
    assert result['camera_restored']
  end

  def test_horizontal_fov_that_cannot_be_reconstructed_is_rejected_before_camera_change
    @view.camera.fov_is_height = false
    @view.camera.aspect_ratio = 1.6
    @initial_state = HomeCAD::Capture.camera_state(@view.camera)
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Capture.capture(@model, 'view' => 'iso')
    end
    assert_equal 'constraint_violation', error.category
    assert_equal @initial_state, HomeCAD::Capture.camera_state(@view.camera)
    assert_equal 0, @view.camera_assignments || 0
  end

  def test_two_point_perspective_still_rejects_changing_capture
    @view.camera.two_point = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Capture.capture(@model, 'view' => 'top')
    end
    assert_equal 'invalid_request', error.category
    assert_equal 0, @view.camera_assignments || 0
  end
end
