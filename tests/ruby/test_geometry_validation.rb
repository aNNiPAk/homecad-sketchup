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
end
