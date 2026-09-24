module HomeCAD
  module Inspection
    def self.list(model, params)
      check_keys!(params, %w[context parent entity_type include_hidden include_generated limit offset])
      limit, offset = Scene.page!(params)
      context = params.fetch('context', 'root')
      unless %w[root active].include?(context) && [true, false].include?(params.fetch('include_hidden', false)) &&
             [true, false].include?(params.fetch('include_generated', false))
        invalid!('invalid list context or visibility flag')
      end
      type = params['entity_type']
      invalid!('entity_type must be a string') if type && !type.is_a?(String)
      entries = Scene.collection(model, context: context, parent: params['parent'])
      entries = entries.select do |entry|
        entity = entry.entity
        next false if type && Scene.type(entity) != type
        next false if !type && %w[Face Edge].include?(Scene.type(entity))
        next false if !params.fetch('include_hidden', false) && entity.respond_to?(:hidden?) && entity.hidden?
        next false if !params.fetch('include_generated', false) && Targeting.metadata(entity)['generated']

        true
      end
      page(entries, limit, offset)
    end

    def self.find(model, params)
      check_keys!(params, Targeting::FILTER_KEYS + %w[instance_path limit offset])
      limit, offset = Scene.page!(params)
      filters = params.reject { |key, _| %w[limit offset].include?(key) }
      Targeting.validate_filters!(filters)
      entries = Targeting.find(model, filters)
      result = page(entries, limit, offset)
      result['resolution'] = if entries.empty?
                               'none'
                             elsif entries.length == 1
                               'unique'
                             elsif (filters.keys & (Targeting::ID_KEYS + ['instance_path'])).any?
                               'ambiguous'
                             else
                               'multiple'
                             end
      result
    end

    def self.get(model, params)
      check_keys!(params, %w[target])
      Serializer.serialize(Targeting.resolve_one(model, params['target']), level: 'detailed')
    end

    def self.selection(model, params)
      check_keys!(params, [])
      selected = model.selection.to_a
      entries = []
      unless selected.empty?
        Scene.walk(model) { |entry| entries << entry if selected.any? { |entity| entity.equal?(entry.entity) } }
      end
      { 'objects' => entries.map { |entry| Serializer.serialize(entry, level: 'standard') },
        'total' => entries.length }
    end

    def self.page(entries, limit, offset)
      { 'objects' => entries.slice(offset, limit).to_a.map { |entry| Serializer.serialize(entry) },
        'total' => entries.length, 'limit' => limit, 'offset' => offset,
        'has_more' => offset + limit < entries.length }
    end

    def self.check_keys!(params, allowed)
      invalid!('unsupported parameters') unless (params.keys - allowed).empty?
    end

    def self.invalid!(message)
      raise Runtime::BridgeError.new(-32602, 'invalid_request', message)
    end
  end
end
