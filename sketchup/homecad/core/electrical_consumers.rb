module HomeCAD
  module ElectricalConsumers
    KEY = 'electrical_consumers_json'.freeze
    KEYS = %w[name source_object_id connection rated_power_w voltage_v point_id description].freeze
    MAX_CONSUMERS = 1024

    def self.records(model)
      records = ElectricalData.parse(model.get_attribute(Metadata::DICTIONARY, KEY, '[]'), Array)
      valid = records.length <= MAX_CONSUMERS && records.all? do |r|
        r.is_a?(Hash) && Metadata.uuid?(r['homecad_id']) && r['type'] == 'electrical.consumer' &&
          r['schema_version'] == 1 && r['revision'].is_a?(Integer) && r['revision'].positive? && r['parameters'].is_a?(Hash)
      end
      raise Runtime::BridgeError.new(-32603, 'invalid_response', 'invalid Consumer registry') unless valid && records.map { |r| r['homecad_id'] }.uniq.length == records.length
      records
    end

    def self.write(model, records)
      model.set_attribute(Metadata::DICTIONARY, KEY, JSON.generate(records))
    end

    def self.resolve(model, target) = Targeting.resolve_record(records(model), target)

    def self.source(model, id)
      entry = Targeting.resolve_one(model, { 'homecad_id' => id })
      Architecture.constraint!('Consumer source must be a semantic kitchen.appliance') unless Metadata.read(entry.entity)['type'] == 'kitchen.appliance'
      entry.entity
    end

    def self.point(model, id)
      return nil unless id
      Electrical.resolve(model, { 'homecad_id' => id })
    end

    def self.circuit_id(model, params, deleted: [])
      return nil unless params['point_id']
      entity = point(model, params['point_id'])
      ElectricalData.read(entity)['circuit_id']
    rescue Runtime::BridgeError => error
      raise unless %w[target_not_found constraint_violation].include?(error.category)
      old = deleted.find { |item| item['homecad_id'] == params['point_id'] }
      old&.dig('parameters', 'circuit_id')
    end

    def self.compatible?(connection, entity)
      type = Metadata.read(entity)['type']
      connection == 'outlet' ? type == 'electrical.outlet' : %w[electrical.connection_point electrical.junction_box].include?(type)
    end

    def self.validate(model, input, defaults = {}, except_id: nil)
      Primitives.check_keys!(input, KEYS)
      values = { 'connection' => 'outlet', 'rated_power_w' => nil, 'voltage_v' => nil,
        'point_id' => nil, 'description' => nil }.merge(defaults).merge(input)
      Circuits.validate(values.slice('name', 'description'))
      Primitives.invalid!('source_object_id requires HomeCAD UUID') unless Metadata.uuid?(values['source_object_id'])
      source(model, values['source_object_id'])
      Architecture.constraint!('appliance already has a Consumer') if records(model).any? { |r| r['homecad_id'] != except_id && r['parameters']['source_object_id'] == values['source_object_id'] }
      Primitives.invalid!('connection must be outlet or direct') unless %w[outlet direct].include?(values['connection'])
      unless values['rated_power_w'].nil?
        power = Geometry.finite_number(values['rated_power_w'], 'rated_power_w')
        Primitives.invalid!('rated_power_w must be nonnegative') if power.negative?
        values['rated_power_w'] = power
      end
      values['voltage_v'] = Geometry.positive_length(values['voltage_v'], 'voltage_v') unless values['voltage_v'].nil?
      Primitives.invalid!('point_id must be null or a HomeCAD UUID') unless values['point_id'].nil? || Metadata.uuid?(values['point_id'])
      if values['point_id']
        entity = point(model, values['point_id'])
        Architecture.constraint!('Consumer connection is incompatible with ElectricalPoint type') unless compatible?(values['connection'], entity)
      end
      values
    end

    def self.create(model, request)
      params = validate(model, request); current = records(model)
      Architecture.constraint!('at most 1024 Consumers supported') if current.length >= MAX_CONSUMERS
      record = { 'homecad_id' => SecureRandom.uuid, 'type' => 'electrical.consumer',
        'schema_version' => 1, 'revision' => 1, 'generated' => false, 'parameters' => params }
      Operation.run('Create Consumer', model: model) do
        write(model, current + [record])
        MutationResult.success(operation: 'create_consumer', created: [Circuits.serialize(record)],
          updated: Circuits.bump(model, [circuit_id(model, params)]), revision: 1)
      end
    end

    def self.get(model, request)
      Primitives.check_keys!(request, %w[target])
      record = resolve(model, request['target'])
      Circuits.serialize(record).merge('circuit_id' => circuit_id(model, record['parameters']))
    end

    def self.list(model, request)
      Primitives.check_keys!(request, %w[limit offset]); limit, offset = Circuits.page(request)
      all = records(model)
      { 'consumers' => (all.slice(offset, limit) || []).map { |r| Circuits.serialize(r) },
        'total' => all.length, 'limit' => limit, 'offset' => offset, 'has_more' => offset + limit < all.length }
    end

    def self.update(model, request = nil, operation: 'update_consumer', **fields)
      request ||= fields
      Primitives.check_keys!(request, %w[target changes]); record = resolve(model, request['target'])
      changes = request['changes']
      Primitives.invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      params = validate(model, changes, record['parameters'], except_id: record['homecad_id'])
      return MutationResult.success(operation: operation, updated: [Circuits.serialize(record)], revision: record['revision']) if params == record['parameters']
      ids = [circuit_id(model, record['parameters']), circuit_id(model, params)]
      Operation.run('Update Consumer', model: model) do
        current = records(model); updated = current.find { |r| r['homecad_id'] == record['homecad_id'] }
        updated['parameters'] = params; updated['revision'] += 1; write(model, current)
        MutationResult.success(operation: operation, updated: [Circuits.serialize(updated)] + Circuits.bump(model, ids), revision: updated['revision'])
      end
    end

    def self.connect(model, request)
      Primitives.check_keys!(request, %w[target point_id]); Primitives.invalid!('point_id is required (null disconnects)') unless request.key?('point_id')
      update(model, { 'target' => request['target'], 'changes' => { 'point_id' => request['point_id'] } }, operation: 'connect_consumer')
    end

    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target]); record = resolve(model, request['target'])
      Operation.run('Delete Consumer', model: model) do
        write(model, records(model).reject { |r| r['homecad_id'] == record['homecad_id'] })
        MutationResult.success(operation: 'delete_consumer', deleted: [Circuits.serialize(record)],
          updated: Circuits.bump(model, [circuit_id(model, record['parameters'])]), revision: record['revision'])
      end
    end

    def self.unpowered_status(model, params)
      return 'missing_point' unless params['point_id']
      entity = point(model, params['point_id'])
      return 'incompatible_connection' unless compatible?(params['connection'], entity)
      id = ElectricalData.read(entity)['circuit_id']
      return 'point_not_on_circuit' unless id
      Circuits.resolve(model, { 'homecad_id' => id })
      nil
    rescue Runtime::BridgeError => error
      raise unless %w[target_not_found constraint_violation].include?(error.category)
      entity ? 'circuit_missing' : 'point_missing'
    end

    def self.unpowered(model, request)
      Primitives.check_keys!(request, %w[limit offset]); limit, offset = Circuits.page(request)
      entries = records(model).filter_map do |record|
        status = unpowered_status(model, record['parameters'])
        { 'consumer_id' => record['homecad_id'], 'source_object_id' => record['parameters']['source_object_id'], 'status' => status } if status
      end
      { 'consumers' => entries.slice(offset, limit) || [], 'total' => entries.length,
        'limit' => limit, 'offset' => offset, 'has_more' => offset + limit < entries.length }
    end

    def self.load(model, request)
      Primitives.check_keys!(request, %w[target]); circuit = Circuits.resolve(model, request['target']); id = circuit['homecad_id']
      entries = records(model).select { |r| circuit_id(model, r['parameters']) == id }
      powers = entries.map { |r| r['parameters']['rated_power_w'] }.compact
      voltage = circuit['parameters']['voltage_v']; known_power = powers.sum
      mismatch = entries.any? { |r| r['parameters']['voltage_v'] && voltage && (r['parameters']['voltage_v']-voltage).abs > 0.01 }
      warnings = ['informational sum of explicit rated power; no diversity, phase, power-factor or protective-device sizing']
      warnings << 'some consumer powers are unknown; total is incomplete' if powers.length < entries.length
      warnings << 'explicit consumer and circuit voltage mismatch' if mismatch
      warnings << 'circuit voltage is unknown' unless voltage
      warnings << 'some consumer voltages are unknown; compatibility is unverified' if entries.any? { |r| r['parameters']['voltage_v'].nil? }
      { 'circuit_id' => id, 'consumer_ids' => entries.map { |r| r['homecad_id'] },
        'known_consumer_count' => powers.length, 'unknown_power_count' => entries.length-powers.length,
        'rated_power_w' => known_power, 'voltage_v' => voltage,
        'estimated_current_a' => voltage && !mismatch && (entries.empty? || powers.any?) ? known_power / voltage : nil, 'warnings' => warnings }
    end
  end
end
