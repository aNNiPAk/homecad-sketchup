module HomeCAD
  module ElectricalData
    PARAMS_KEY = 'electrical_parameters_json'.freeze
    CIRCUITS_KEY = 'electrical_circuits_json'.freeze
    MAX_CIRCUITS = 512

    def self.parse(raw, expected)
      value = JSON.parse(raw)
      raise 'wrong stored value type' unless value.is_a?(expected)
      value
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32603, 'invalid_response', "invalid Electrical metadata: #{error.message}")
    end

    def self.read(entity)
      parse(Metadata.read(entity).fetch(PARAMS_KEY, '{}'), Hash)
    end

    def self.write(entity, params)
      entity.set_attribute(Metadata::DICTIONARY, PARAMS_KEY, JSON.generate(params))
      entity.set_attribute(Metadata::DICTIONARY, 'circuit_id', params['circuit_id'])
      placement = params['placement']
      if placement['mode'] == 'wall'
        size = params['dimensions_mm']
        projected = { 'mode' => 'wall', 'wall_id' => placement['wall_id'],
          'offset_mm' => placement['offset_mm'] - size['width_mm'] / 2,
          'bottom_mm' => placement['height_mm'] - size['height_mm'] / 2,
          'side' => placement['side'], 'clearance_mm' => placement['clearance_mm'] }
        WallAttachment.sync!(entity, placement: projected,
          span_u_mm: size['width_mm'], span_z_mm: size['height_mm'])
      else
        WallAttachment.clear!(entity)
      end
    end

    def self.circuits(model)
      records = parse(model.get_attribute(Metadata::DICTIONARY, CIRCUITS_KEY, '[]'), Array)
      valid = records.length <= MAX_CIRCUITS && records.all? do |record|
        record.is_a?(Hash) && Metadata.uuid?(record['homecad_id']) &&
          record['type'] == 'electrical.circuit' && record['schema_version'] == 1 &&
          record['revision'].is_a?(Integer) && record['revision'].positive? && record['parameters'].is_a?(Hash)
      end
      unless valid && records.map { |record| record['homecad_id'] }.uniq.length == records.length
        raise Runtime::BridgeError.new(-32603, 'invalid_response', 'invalid or duplicate stored circuits')
      end
      records
    end

    def self.write_circuits(model, records)
      model.set_attribute(Metadata::DICTIONARY, CIRCUITS_KEY, JSON.generate(records))
    end
  end
end
