module HomeCAD
  module Targeting
    ID_KEYS = %w[homecad_id persistent_id entity_id].freeze
    FILTER_KEYS = (ID_KEYS + %w[entity_type homecad_type name tag parent_id metadata]).freeze

    def self.metadata(entity)
      dictionary = entity.respond_to?(:attribute_dictionary) ? entity.attribute_dictionary('HomeCAD', false) : nil
      return {} unless dictionary

      dictionary.each_pair.to_h { |key, value| [key.to_s, value] }
    end

    def self.identity(entry)
      entity = entry.entity
      data = metadata(entity)
      { 'homecad_id' => data['homecad_id'],
        'persistent_id' => entity.respond_to?(:persistent_id) ? entity.persistent_id : nil,
        'entity_id' => entity.respond_to?(:entityID) ? entity.entityID : nil,
        'instance_path' => entry.path }
    end

    def self.resolve_one(model, selector)
      validate_selector!(selector)
      matches = find(model, selector, stop_after: 2)
      raise Runtime::BridgeError.new(-32002, 'target_not_found', 'target not found') if matches.empty?
      raise Runtime::BridgeError.new(-32003, 'ambiguous_target', 'target matches multiple objects or placements') if matches.length > 1

      matches.first
    end

    def self.validate_selector!(selector)
      unless selector.is_a?(Hash) && ID_KEYS.any? { |key| selector.key?(key) } &&
             (selector.keys - ID_KEYS - ['instance_path']).empty?
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'target requires a supported identity selector')
      end
      if selector.key?('instance_path') && (!selector['instance_path'].is_a?(Array) || selector['instance_path'].empty?)
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'instance_path must be a nonempty array')
      end
    end

    def self.validate_filters!(filters)
      unless filters.is_a?(Hash) && !filters.empty? && (filters.keys - FILTER_KEYS - ['instance_path']).empty?
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'find_objects requires supported filters')
      end
      if filters.key?('metadata') && !filters['metadata'].is_a?(Hash)
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'metadata must be an object')
      end
    end

    def self.find(model, filters, stop_after: nil)
      matches = []
      # SketchUp's native lookup avoids a model scan for missing exact IDs. A successful
      # lookup still traverses placements, because one definition entity can be instanced.
      if filters.key?('persistent_id') && model.respond_to?(:find_entity_by_persistent_id)
        return [] unless model.find_entity_by_persistent_id(filters['persistent_id'])
      elsif filters.key?('entity_id') && model.respond_to?(:find_entity_by_id)
        return [] unless model.find_entity_by_id(filters['entity_id'])
      end
      Scene.walk(model) do |entry|
        next unless match?(entry, filters)

        matches << entry
        break if stop_after && matches.length >= stop_after
      end
      matches
    end

    def self.match?(entry, filters)
      entity = entry.entity
      identity = identity(entry)
      filters.all? do |key, value|
        case key
        when *ID_KEYS then identity[key] == value
        when 'instance_path' then entry.path == value
        when 'entity_type' then Scene.type(entity) == value
        when 'homecad_type' then metadata(entity)['type'] == value
        when 'name' then entity.respond_to?(:name) && entity.name.to_s.downcase.include?(value.to_s.downcase)
        when 'tag' then entity.respond_to?(:layer) && entity.layer && entity.layer.name == value
        when 'parent_id' then entry.parent && Scene.id(entry.parent) == value
        when 'metadata' then value.all? { |k, v| metadata(entity)[k] == v }
        else false
        end
      end
    end
  end
end
