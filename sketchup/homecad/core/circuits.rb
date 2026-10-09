module HomeCAD
  module Circuits
    KEYS = %w[name voltage_v cable_label protection_label description].freeze

    def self.validate(input, defaults = {})
      Primitives.check_keys!(input, KEYS)
      values = { 'voltage_v' => nil, 'cable_label' => nil, 'protection_label' => nil,
        'description' => nil }.merge(defaults).merge(input)
      %w[name cable_label protection_label description].each do |key|
        value = values[key]
        valid = value.nil? && key != 'name' || value.is_a?(String) && !value.strip.empty? && value.length <= (key == 'description' ? 1024 : 128)
        Primitives.invalid!("#{key} must be a bounded nonempty string") unless valid
      end
      values['voltage_v'] = Geometry.positive_length(values['voltage_v'], 'voltage_v') unless values['voltage_v'].nil?
      values
    end

    def self.members(model, id)
      return [] unless defined?(Electrical)
      Electrical.points(model).select { |entity| ElectricalData.read(entity)['circuit_id'] == id }
    end

    def self.serialize(record)
      identity = { 'homecad_id' => record['homecad_id'], 'persistent_id' => nil,
        'entity_id' => nil, 'instance_path' => [] }
      { 'identity' => identity, 'homecad_id' => record['homecad_id'],
        'homecad_type' => record['type'], 'entity_type' => nil,
        'metadata' => record.reject { |key, _| key == 'parameters' }, 'parameters' => record['parameters'] }
    end

    def self.result(operation, record, **objects)
      MutationResult.success(operation: operation, revision: record['revision'], **objects)
    end

    def self.resolve(model, target)
      Targeting.resolve_record(ElectricalData.circuits(model), target)
    end

    def self.create(model, request)
      params = validate(request)
      records = ElectricalData.circuits(model)
      Architecture.constraint!('at most 512 circuits are supported') if records.length >= ElectricalData::MAX_CIRCUITS
      record = { 'homecad_id' => SecureRandom.uuid, 'type' => 'electrical.circuit',
        'schema_version' => 1, 'revision' => 1, 'generated' => false, 'parameters' => params }
      Operation.run('Create circuit', model: model) do
        ElectricalData.write_circuits(model, records + [record])
        result('create_circuit', record, created: [serialize(record)])
      end
    end

    def self.get(model, request)
      Primitives.check_keys!(request, %w[target])
      record = resolve(model, request['target'])
      serialize(record).merge('member_ids' => members(model, record['homecad_id']).map { |entity| Metadata.read(entity)['homecad_id'] })
    end

    def self.page(request)
      limit = request.fetch('limit', 50); offset = request.fetch('offset', 0)
      Primitives.invalid!('limit must be 1..100 and offset nonnegative') unless
        limit.is_a?(Integer) && (1..100).cover?(limit) && offset.is_a?(Integer) && offset >= 0
      [limit, offset]
    end

    def self.list(model, request)
      Primitives.check_keys!(request, %w[limit offset])
      limit, offset = page(request)
      records = ElectricalData.circuits(model)
      { 'circuits' => (records.slice(offset, limit) || []).map { |record| serialize(record) },
        'total' => records.length, 'limit' => limit, 'offset' => offset, 'has_more' => offset + limit < records.length }
    end

    def self.update(model, request)
      Primitives.check_keys!(request, %w[target changes])
      record = resolve(model, request['target'])
      changes = request['changes']
      Primitives.invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      proposed = validate(changes, record['parameters'])
      return result('update_circuit', record, updated: [serialize(record)]) if proposed == record['parameters']
      Operation.run('Update circuit', model: model) do
        records = ElectricalData.circuits(model)
        changed = records.find { |item| item['homecad_id'] == record['homecad_id'] }
        changed['parameters'] = proposed; changed['revision'] += 1
        ElectricalData.write_circuits(model, records)
        result('update_circuit', changed, updated: [serialize(changed)])
      end
    end

    # Called only inside an already active operation. Increment each affected chain once.
    def self.bump(model, ids)
      ids = ids.compact.uniq
      return [] if ids.empty?
      records = ElectricalData.circuits(model)
      affected = records.select { |record| ids.include?(record['homecad_id']) }
      affected.each { |record| record['revision'] += 1 }
      ElectricalData.write_circuits(model, records)
      affected.map { |record| serialize(record) }
    end

    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target detach_points])
      record = resolve(model, request['target'])
      detach = request.fetch('detach_points', false)
      Primitives.invalid!('detach_points must be boolean') unless [true, false].include?(detach)
      points = members(model, record['homecad_id'])
      Architecture.constraint!('circuit has points; set detach_points=true') if points.any? && !detach
      points.each { |entity| Architecture.require_mutable!(entity) }
      Operation.run('Delete circuit', model: model) do
        points.each do |entity|
          ElectricalData.write(entity, ElectricalData.read(entity).merge('circuit_id' => nil))
          Metadata.increment_revision!(entity)
        end
        ElectricalData.write_circuits(model, ElectricalData.circuits(model).reject { |item| item['homecad_id'] == record['homecad_id'] })
        result('delete_circuit', record, deleted: [serialize(record)],
          updated: points.map { |entity| Furniture.serialize_entity(entity) })
      end
    end
  end
end
