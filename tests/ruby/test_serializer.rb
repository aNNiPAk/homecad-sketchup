require 'minitest/autorun'

module HomeCAD
  module Runtime
    class BridgeError < StandardError
      def initialize(*) = super
    end
  end
end

root = File.expand_path('../../sketchup/homecad/core', __dir__)
%w[units scene targeting serializer].each { |name| require File.join(root, name) }

Point = Struct.new(:x, :y, :z) do
  def transform(_matrix) = self
end
Box = Struct.new(:empty) do
  def empty? = empty
  def corner(i) = Point.new(i & 1, (i >> 1) & 1, (i >> 2) & 1)
end
Entity = Struct.new(:persistent_id, :entityID, :typename, :name, :bounds, keyword_init: true) do
  def attribute_dictionary(*) = nil
  def valid? = true
end

class SerializerTest < Minitest::Test
  def setup
    entity = Entity.new(persistent_id: 7, entityID: 17, typename: 'Group', name: 'Cabinet', bounds: Box.new(false))
    @entry = HomeCAD::Scene::Entry.new(entity: entity, parent: nil, path: [7], transform: nil)
  end

  def test_levels_share_identity_and_summary
    summary = HomeCAD::Serializer.serialize(@entry)
    standard = HomeCAD::Serializer.serialize(@entry, level: 'standard')
    detailed = HomeCAD::Serializer.serialize(@entry, level: 'detailed')
    assert_equal summary, standard.slice(*summary.keys)
    assert_equal summary, detailed.slice(*summary.keys)
    assert_nil detailed['identity']['homecad_id']
    assert_equal 7, detailed['identity']['persistent_id']
    assert_equal 17, detailed['identity']['entity_id']
    assert_equal 25.4, detailed['dimensions_mm']['width']
    assert_equal 25.4, detailed['dimensions_mm']['height']
  end

  def test_empty_bounds_are_null
    @entry.entity.bounds = Box.new(true)
    assert_nil HomeCAD::Serializer.serialize(@entry, level: 'standard')['bbox_mm']
  end
end
