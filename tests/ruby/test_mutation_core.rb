require 'minitest/autorun'

module Sketchup
  def self.active_model = @model
  def self.active_model=(model)
    @model = model
  end
end

require_relative '../../sketchup/homecad/runtime/errors'
require_relative '../../sketchup/homecad/runtime/operation'
require_relative '../../sketchup/homecad/core/metadata'
require_relative '../../sketchup/homecad/core/mutation'

class MutationEntity
  attr_reader :attributes, :parent
  attr_accessor :locked, :valid

  def initialize(attributes = {}, parent: nil)
    @attributes = attributes
    @parent = parent
    @locked = false
    @valid = true
  end

  def attribute_dictionary(name, _create = false)
    @attributes[name]
  end

  def set_attribute(dictionary, key, value)
    (@attributes[dictionary] ||= {})[key] = value
  end

  def valid? = @valid
  def deleted? = !@valid
  def locked? = @locked
end

class MutationCoreTest < Minitest::Test
  def test_uuid_metadata_fields_and_uniqueness
    one = MutationEntity.new
    two = MutationEntity.new
    metadata_one = HomeCAD::Metadata.create!(one, type: 'primitive.box')
    metadata_two = HomeCAD::Metadata.create!(two, type: 'primitive.box')

    assert HomeCAD::Metadata.uuid?(metadata_one['homecad_id'])
    assert HomeCAD::Metadata.uuid?(metadata_two['homecad_id'])
    refute_equal metadata_one['homecad_id'], metadata_two['homecad_id']
    assert_equal({ 'homecad_id' => metadata_one['homecad_id'], 'type' => 'primitive.box',
                   'schema_version' => 1, 'revision' => 1, 'generated' => true }, metadata_one)
  end

  def test_revision_increments_and_existing_metadata_is_preserved
    entity = MutationEntity.new
    HomeCAD::Metadata.write(entity, type: 'primitive.box', generated: true, revision: 4)
    entity.set_attribute('HomeCAD', 'custom', 'keep')

    updated = HomeCAD::Metadata.increment_revision!(entity)
    assert_equal 5, updated['revision']
    assert_equal 'keep', entity.attributes['HomeCAD']['custom']
  end

  def test_unmanaged_existing_target_becomes_external_on_first_mutation
    metadata = HomeCAD::Metadata.increment_revision!(MutationEntity.new)
    assert HomeCAD::Metadata.uuid?(metadata['homecad_id'])
    assert_equal 'primitive.external', metadata['type']
    assert_equal false, metadata['generated']
    assert_equal 1, metadata['revision']
  end

  def test_locked_invalid_and_generated_domain_targets_are_rejected
    model = Object.new
    unlocked_parent = MutationEntity.new
    entity = MutationEntity.new({}, parent: unlocked_parent)
    entry = Struct.new(:entity, :parent).new(entity, unlocked_parent)
    assert_same entity, HomeCAD::MutationPolicy.validate_target!(entry, model: model)

    unlocked_parent.locked = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::MutationPolicy.validate_target!(entry, model: model)
    end
    assert_equal 'constraint_violation', error.category

    unlocked_parent.locked = false
    HomeCAD::Metadata.write(entity, type: 'architecture.wall', generated: true)
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::MutationPolicy.validate_target!(entry, model: model)
    end
    assert_equal 'constraint_violation', error.category

    entity.valid = false
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::MutationPolicy.validate_target!(entry, model: model)
    end
    assert_equal 'target_not_found', error.category
  end

  def test_mutation_result_uses_shared_structured_envelope
    entity = { 'identity' => { 'homecad_id' => 'uuid' } }
    result = HomeCAD::MutationResult.success(operation: 'create_box', created: [entity], revision: 1)
    assert_equal HomeCAD::MutationResult::KEYS, result.keys
    assert_equal 'success', result['status']
    assert_equal [entity], result['created']
    assert_equal [], result['updated']
    assert_equal [], result['deleted']
    assert_equal [], result['warnings']
    assert_equal 1, result['revision']
  end

  def test_operation_commits_once_and_aborts_on_exception
    model = Object.new
    events = []
    model.define_singleton_method(:start_operation) { |*| events << :start; true }
    model.define_singleton_method(:commit_operation) { events << :commit; true }
    model.define_singleton_method(:abort_operation) { events << :abort; true }

    HomeCAD::Operation.run('One mutation', model: model) { :done }
    assert_equal %i[start commit], events
    assert_raises(RuntimeError) do
      HomeCAD::Operation.run('Failed mutation', model: model) { raise 'invalid geometry' }
    end
    assert_equal %i[start commit start abort], events
  end
end
