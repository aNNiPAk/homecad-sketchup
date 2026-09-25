require 'json'

module HomeCAD
  module FurnitureData
    PARAMS_KEY = 'furniture_params_json'.freeze
    RELATIONSHIPS_KEY = 'furniture_relationships_json'.freeze

    def self.read_params(entity)
      read_json(entity, PARAMS_KEY)
    end

    def self.read_relationships(entity)
      read_json(entity, RELATIONSHIPS_KEY)
    end

    def self.write(entity, params:)
      placement = params['placement']
      relationships = placement.is_a?(Hash) && placement['mode'] == 'wall' ?
        { 'wall_id' => placement['wall_id'] } : {}
      entity.set_attribute(Metadata::DICTIONARY, PARAMS_KEY, JSON.generate(canonical(params)))
      entity.set_attribute(Metadata::DICTIONARY, RELATIONSHIPS_KEY, JSON.generate(canonical(relationships)))
      WallAttachment.sync!(entity, params)
      true
    end

    def self.read_json(entity, key)
      value = Metadata.read(entity)[key]
      return {} unless value.is_a?(String) && !value.empty?

      parsed = JSON.parse(value)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      raise Runtime::BridgeError.new(-32603, 'invalid_response', "stored #{key} is malformed")
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key.to_s, canonical(value[key])] }
      when Array then value.map { |item| canonical(item) }
      when String, Numeric, TrueClass, FalseClass, NilClass then value
      else
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'furniture metadata must contain JSON values')
      end
    end
  end
end
