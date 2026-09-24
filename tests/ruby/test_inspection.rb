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
%w[units scene targeting serializer inspection].each { |name| require File.join(root, name) }

Thing = Struct.new(:persistent_id, :entityID, :typename, :name, :hidden, keyword_init: true) do
  def attribute_dictionary(*) = nil
  def hidden? = hidden
  def valid? = true
end
Model = Struct.new(:entities, :active_entities, :selection, keyword_init: true) do
  def find_entity_by_persistent_id(id) = entities.find { |item| item.persistent_id == id }
  def find_entity_by_id(id) = entities.find { |item| item.entityID == id }
end

class InspectionTest < Minitest::Test
  def setup
    @one = Thing.new(persistent_id: 1, entityID: 10, typename: 'Group', name: 'Chair')
    @two = Thing.new(persistent_id: 2, entityID: 20, typename: 'Group', name: 'Chair 2')
    edge = Thing.new(persistent_id: 3, entityID: 30, typename: 'Edge', name: '')
    hidden = Thing.new(persistent_id: 4, entityID: 40, typename: 'Group', name: 'Hidden', hidden: true)
    @model = Model.new(entities: [@one, @two, edge, hidden], active_entities: [@one], selection: [@two])
  end

  def test_bounded_listing_and_topology
    page = HomeCAD::Inspection.list(@model, 'limit' => 1, 'offset' => 1)
    assert_equal 2, page['total']
    assert_equal 2, page['objects'][0]['identity']['persistent_id']
    refute page['has_more']
    assert_equal 1, HomeCAD::Inspection.list(@model, 'entity_type' => 'Edge')['total']
    assert_equal 3, HomeCAD::Inspection.list(@model, 'include_hidden' => true)['total']
  end

  def test_find_resolution_and_missing_target
    assert_equal 'multiple', HomeCAD::Inspection.find(@model, 'name' => 'Chair')['resolution']
    assert_equal 'unique', HomeCAD::Inspection.find(@model, 'persistent_id' => 1)['resolution']
    assert_equal 'none', HomeCAD::Inspection.find(@model, 'persistent_id' => 999)['resolution']
    assert_equal 'target_not_found', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Inspection.get(@model, 'target' => { 'persistent_id' => 999 })
    }.category
  end

  def test_get_and_selection_share_serializer
    object = HomeCAD::Inspection.get(@model, 'target' => { 'persistent_id' => 2 })
    selected = HomeCAD::Inspection.selection(@model, {})['objects'][0]
    assert_equal object['identity'], selected['identity']
    assert_equal object['entity_type'], selected['entity_type']
  end
end
