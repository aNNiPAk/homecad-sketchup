require 'json'

module HomeCAD
  module MultiWallAttachment
    KEY = 'host_wall_ids_json'.freeze

    def self.sync!(entity, wall_ids)
      unless wall_ids.is_a?(Array) && wall_ids.length == 2 && wall_ids.uniq.length == 2 &&
             wall_ids.all? { |id| id.is_a?(String) && Metadata.uuid?(id) }
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'multi-wall host IDs must be two distinct HomeCAD UUIDs')
      end
      entity.set_attribute(Metadata::DICTIONARY, KEY, JSON.generate(wall_ids))
    end

    def self.read(entity)
      raw = Metadata.read(entity)[KEY]
      return [] unless raw.is_a?(String)

      ids = JSON.parse(raw)
      raise JSON::ParserError unless ids.is_a?(Array) && ids.length == 2 && ids.uniq.length == 2

      ids
    rescue JSON::ParserError
      raise Runtime::BridgeError.new(-32603, 'invalid_response', 'stored multi-wall attachment is malformed')
    end

    def self.dependents_for(model, wall_id)
      model.entities.to_a.select do |entity|
        Metadata.read(entity)['type'] == 'kitchen.run' && read(entity).include?(wall_id)
      end
    end
  end
end
