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
end

root = File.expand_path('../../sketchup/homecad/core', __dir__)
%w[units scene targeting serializer inspection measurement].each { |name| require File.join(root, name) }

P3 = Struct.new(:x, :y, :z) do
  def transform(*) = self
end
BB = Struct.new(:start_x) do
  def empty? = false
  def corner(i) = P3.new(start_x + (i & 1), (i >> 1) & 1, (i >> 2) & 1)
end
Shape = Struct.new(:persistent_id, :entityID, :typename, :name, :bounds, keyword_init: true) do
  def attribute_dictionary(*) = nil
  def area(*) = 2.0
  def length(*) = 3.0
end
M = Struct.new(:entities) do
  def find_entity_by_persistent_id(id) = entities.find { |item| item.persistent_id == id }
end

class MeasurementTest < Minitest::Test
  def setup
    a = Shape.new(persistent_id: 1, entityID: 10, typename: 'Group', name: 'A', bounds: BB.new(0))
    b = Shape.new(persistent_id: 2, entityID: 20, typename: 'Group', name: 'B', bounds: BB.new(3))
    face = Shape.new(persistent_id: 3, entityID: 30, typename: 'Face', bounds: BB.new(0))
    edge = Shape.new(persistent_id: 4, entityID: 40, typename: 'Edge', bounds: BB.new(0))
    @model = M.new([a, b, face, edge])
  end

  def measure(kind, id = 1, other = nil)
    params = { 'kind' => kind, 'target' => { 'persistent_id' => id } }
    params['other_target'] = { 'persistent_id' => other } if other
    HomeCAD::Measurement.measure(@model, params)
  end

  def test_dimensions_and_distances
    assert_equal 25.4, measure('dimensions')['value']['width']
    assert_in_delta 76.2, measure('center_distance', 1, 2)['value'], 0.0001
    assert_in_delta 50.8, measure('bbox_distance', 1, 2)['value'], 0.0001
    assert_equal 2, measure('center_distance', 1, 2)['targets'].length
  end

  def test_area_length_and_schema
    assert_in_delta 1290.32, measure('face_area', 3)['value'], 0.0001
    assert_equal 'mm²', measure('face_area', 3)['unit']
    assert_in_delta 76.2, measure('edge_length', 4)['value'], 0.0001
    assert_equal 'bounds', measure('bounds')['kind']
  end

  def test_type_and_missing_target_errors
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      measure('face_area', 1)
    }.category
    assert_equal 'target_not_found', assert_raises(HomeCAD::Runtime::BridgeError) {
      measure('bounds', 999)
    }.category
  end
end
