require 'securerandom'

module HomeCAD
  module Metadata
    DICTIONARY = 'HomeCAD'.freeze
    SCHEMA_VERSION = 1
    FIELDS = %w[homecad_id type schema_version revision generated].freeze

    def self.read(entity)
      dictionary = entity.respond_to?(:attribute_dictionary) ? entity.attribute_dictionary(DICTIONARY, false) : nil
      return {} unless dictionary

      values = {}
      dictionary.each_pair { |key, value| values[key.to_s] = value }
      values
    end

    def self.write(entity, type:, generated:, homecad_id: nil, revision: 1)
      unless type.is_a?(String) && /\A[a-z][a-z0-9_.]*\z/.match?(type)
        raise ArgumentError, 'type must be a stable lowercase dotted identifier'
      end
      unless generated == true || generated == false
        raise ArgumentError, 'generated must be a boolean'
      end
      unless revision.is_a?(Integer) && revision.positive?
        raise ArgumentError, 'revision must be a positive integer'
      end

      id = homecad_id || SecureRandom.uuid
      raise ArgumentError, 'homecad_id must be a UUID' unless uuid?(id)

      entity.set_attribute(DICTIONARY, 'homecad_id', id)
      entity.set_attribute(DICTIONARY, 'type', type)
      entity.set_attribute(DICTIONARY, 'schema_version', SCHEMA_VERSION)
      entity.set_attribute(DICTIONARY, 'revision', revision)
      entity.set_attribute(DICTIONARY, 'generated', generated)
      read(entity)
    end

    def self.create!(entity, type:)
      write(entity, type: type, generated: true, revision: 1)
    end

    def self.increment_revision!(entity)
      values = read(entity)
      id = values['homecad_id']
      type = values['type'] || 'primitive.external'
      generated = values.key?('generated') ? values['generated'] : false
      revision = values['revision'].is_a?(Integer) && values['revision'].positive? ? values['revision'] + 1 : 1
      write(entity, type: type, generated: generated, homecad_id: id, revision: revision)
    end

    def self.uuid?(value)
      value.is_a?(String) &&
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.match?(value)
    end
  end
end
