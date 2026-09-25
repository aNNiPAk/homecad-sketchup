module HomeCAD
  module MutationPolicy
    PRIMITIVE_TYPE = /\Aprimitive\./

    def self.validate_target!(entry, model: Sketchup.active_model)
      entity = entry.entity
      unless entity.respond_to?(:valid?) && entity.valid? &&
             (!entity.respond_to?(:deleted?) || !entity.deleted?)
        raise Runtime::BridgeError.new(-32002, 'target_not_found', 'target is deleted or invalid')
      end

      current = entity
      parent = entry.parent
      while current && !current.equal?(model)
        if current.respond_to?(:locked?) && current.locked?
          raise Runtime::BridgeError.new(-32008, 'constraint_violation', 'locked targets cannot be mutated')
        end
        current = parent
        parent = current.respond_to?(:parent) ? current.parent : nil
      end

      current = entity
      parent = entry.parent
      while current && !current.equal?(model)
        metadata = Metadata.read(current)
        if metadata['generated'] == true && !PRIMITIVE_TYPE.match?(metadata['type'].to_s)
          raise Runtime::BridgeError.new(-32008, 'constraint_violation',
                                         'generated domain geometry cannot be edited by primitive tools')
        end
        current = parent
        parent = current.respond_to?(:parent) ? current.parent : nil
      end
      entity
    end

    def self.require_type!(entity, klass, label)
      return entity if entity.is_a?(klass)

      raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{label} must be a #{klass}")
    end
  end

  module MutationResult
    KEYS = %w[status operation created updated deleted warnings revision].freeze

    def self.success(operation:, created: [], updated: [], deleted: [], warnings: [], revision:)
      unless revision.is_a?(Integer) && revision.positive?
        raise ArgumentError, 'mutation result revision must be a positive integer'
      end
      {
        'status' => 'success', 'operation' => operation.to_s,
        'created' => created, 'updated' => updated, 'deleted' => deleted,
        'warnings' => warnings, 'revision' => revision
      }
    end
  end
end
