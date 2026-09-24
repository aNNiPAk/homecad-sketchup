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
require File.join(root, 'scene')
require File.join(root, 'targeting')

FakeEntity = Struct.new(:persistent_id, :entityID, :typename, :name, :layer, :entities, :data, keyword_init: true) do
  def attribute_dictionary(_name, _create) = data
end
FakeModel = Struct.new(:entities, :active_entities, keyword_init: true) do
  def find_entity_by_persistent_id(id) = entities.find { |item| item.persistent_id == id }
  def find_entity_by_id(id) = entities.find { |item| item.entityID == id }
end

class TargetingTest < Minitest::Test
  def setup
    @chair = FakeEntity.new(persistent_id: 11, entityID: 101, typename: 'ComponentInstance',
                            name: 'Chair', data: { 'homecad_id' => 'hc-chair', 'type' => 'furniture' })
    @table = FakeEntity.new(persistent_id: 12, entityID: 102, typename: 'Group', name: 'Table')
    @model = FakeModel.new(entities: [@chair, @table], active_entities: [@chair])
  end

  def test_identity_priority_and_native_missing_lookup
    entry = HomeCAD::Targeting.resolve_one(@model, 'homecad_id' => 'hc-chair')
    assert_equal 11, HomeCAD::Targeting.identity(entry)['persistent_id']
    assert_equal [11], HomeCAD::Targeting.identity(entry)['instance_path']
    assert_equal 'target_not_found', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Targeting.resolve_one(@model, 'persistent_id' => 999)
    }.category
  end

  def test_ambiguity_and_instance_path
    same = FakeEntity.new(persistent_id: 11, entityID: 103, typename: 'Group', name: 'Chair')
    @model.entities << same
    assert_equal 'ambiguous_target', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Targeting.resolve_one(@model, 'persistent_id' => 11)
    }.category
    assert_equal @chair, HomeCAD::Targeting.resolve_one(@model,
      'persistent_id' => 11, 'entity_id' => 101).entity
  end

  def test_metadata_and_name_filters
    assert_equal [@chair], HomeCAD::Targeting.find(@model, { 'name' => 'hai' }).map(&:entity)
    assert_equal [@chair], HomeCAD::Targeting.find(@model, { 'metadata' => { 'type' => 'furniture' } }).map(&:entity)
    assert_empty HomeCAD::Targeting.find(@model, { 'homecad_type' => 'wall' })
  end

  def test_page_bounds
    assert_equal [100, 0], HomeCAD::Scene.page!('limit' => 100)
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Scene.page!('limit' => 101)
    }.category
  end
end
