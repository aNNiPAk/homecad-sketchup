module HomeCAD
  module HardwareCatalog
    PATH = File.expand_path('../catalog/hardware.json', __dir__).freeze
    FAMILY_ID = 'homecad.wood_drawer.slide_pair.v1'.freeze

    def self.data
      @data ||= begin
        parsed = JSON.parse(File.read(PATH, encoding: 'UTF-8'))
        raise 'invalid hardware catalog' unless parsed['schema_version'] == 1 &&
          parsed['families'].is_a?(Array) &&
          parsed['families'].map { |family| family['id'] }.uniq.length == parsed['families'].length &&
          parsed['families'].all? do |family|
            family['id'].is_a?(String) && family['unit'].is_a?(String) &&
              family['quantity_per_assembly'].is_a?(Integer) && family['quantity_per_assembly'].positive?
          end

        parsed
      end
    end

    def self.list(_model, params)
      Primitives.check_keys!(params, [])
      # Return a fresh JSON value so callers cannot alter the shared catalog.
      JSON.parse(JSON.generate(data))
    end

    def self.family!(identifier)
      family = data['families'].find { |entry| entry['id'] == identifier }
      raise Runtime::BridgeError.new(-32008, 'constraint_violation',
        "unknown hardware family: #{identifier.inspect}") unless family

      family
    end
  end
end
