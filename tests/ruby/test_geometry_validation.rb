require 'minitest/autorun'

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x, @y, @z = x, y, z
    end

    def distance(other)
      Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    end
  end

  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x, @y, @z = x, y, z
    end

    def length
      Math.sqrt(x * x + y * y + z * z)
    end

    def length=(value)
      factor = value / length
      @x *= factor
      @y *= factor
      @z *= factor
    end
    def dot(other) = x * other.x + y * other.y + z * other.z
    def cross(other) = Vector3d.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
  end

  class Transformation
    attr_reader :xaxis, :yaxis, :zaxis
    def initialize(axes = nil)
      @xaxis, @yaxis, @zaxis = axes || [Vector3d.new(1, 0, 0), Vector3d.new(0, 1, 0), Vector3d.new(0, 0, 1)]
    end
    def self.new_with_shear = new([Vector3d.new(1, 0, 0), Vector3d.new(0.5, 1, 0), Vector3d.new(0, 0, 1)])
    def self.translation(*) = new
    def self.rotation(*) = new([Vector3d.new(Math.sqrt(0.5), Math.sqrt(0.5), 0),
                                Vector3d.new(-Math.sqrt(0.5), Math.sqrt(0.5), 0), Vector3d.new(0, 0, 1)])
    def self.scaling(_origin, x, y, z) = new([Vector3d.new(x, 0, 0), Vector3d.new(0, y, 0), Vector3d.new(0, 0, z)])
    def to_a = [xaxis.x, xaxis.y, xaxis.z, 0, yaxis.x, yaxis.y, yaxis.z, 0,
                zaxis.x, zaxis.y, zaxis.z, 0, 0, 0, 0, 1]
  end
end

require_relative '../../sketchup/homecad/runtime/errors'
require_relative '../../sketchup/homecad/core/units'
require_relative '../../sketchup/homecad/core/geometry'

class GeometryValidationTest < Minitest::Test
  def test_public_points_convert_millimeters_to_sketchup_internal_units
    point = HomeCAD::Geometry.point_mm([25.4, 50.8, 0], 'point')
    assert_in_delta 1.0, point.x, 1e-9
    assert_in_delta 2.0, point.y, 1e-9
    assert_in_delta 0.0, point.z, 1e-9
  end

  def test_rejects_nonfinite_values_and_zero_vectors
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.positive_length(Float::NAN, 'radius_mm')
    end
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.point_mm([0, Float::INFINITY, 0], 'point')
    end
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.vector([0, 0, 0], 'normal')
    end
  end

  def test_limits_segments_and_rejects_duplicate_face_points
    assert_equal 512, HomeCAD::Geometry.segments(512, 'segments')
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.segments(513, 'segments')
    end
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.points([[0, 0, 0], [0.001, 0, 0], [0, 10, 0]])
    end
  end

  def test_path_points_are_bounded_and_reject_duplicate_adjacent_points
    points = (0...512).map { |index| [index * 25.4, 0, 0] }
    assert_equal 512, HomeCAD::Geometry.path_points(points).length
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.path_points(points + [[512 * 25.4, 0, 0]])
    end
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Geometry.path_points([[0, 0, 0], [0.001, 0, 0]])
    end
  end

  def test_rigid_transform_detector_rejects_scale_shear_and_reflection
    identity = Geom::Transformation.new
    translation = Geom::Transformation.translation(Geom::Vector3d.new(10, 20, 30))
    rotation = Geom::Transformation.rotation
    uniform = Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), 2, 2, 2)
    shear = Geom::Transformation.new_with_shear
    mirror = Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), -1, 1, 1)
    assert HomeCAD::Geometry.rigid_transform?(identity)
    assert HomeCAD::Geometry.rigid_transform?(translation)
    assert HomeCAD::Geometry.rigid_transform?(rotation)
    refute HomeCAD::Geometry.rigid_transform?(uniform)
    refute HomeCAD::Geometry.rigid_transform?(shear)
    refute HomeCAD::Geometry.rigid_transform?(mirror)
  end
end
