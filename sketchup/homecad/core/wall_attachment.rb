module HomeCAD
  module WallAttachment
    SCHEMA_VERSION = 1
    MARKER_KEY = 'wall_attachment_schema_version'.freeze
    OWNED_KEYS = %w[
      wall_attachment_schema_version attachment_offset_mm attachment_bottom_mm
      attachment_side attachment_clearance_mm attachment_span_u_mm wall_id
    ].freeze
    SIDES = %w[positive_v negative_v].freeze
    TOLERANCE_MM = 0.01

    # The parameter JSON is canonical. These HomeCAD attributes are a searchable
    # projection for dependency scans and never own an independent span value.
    def self.sync!(entity, params)
      placement = params['placement']
      unless placement.is_a?(Hash) && placement['mode'] == 'wall'
        clear!(entity)
        return nil
      end

      entity.set_attribute(Metadata::DICTIONARY, MARKER_KEY, SCHEMA_VERSION)
      entity.set_attribute(Metadata::DICTIONARY, 'wall_id', placement['wall_id'])
      entity.set_attribute(Metadata::DICTIONARY, 'attachment_offset_mm', placement['offset_mm'])
      entity.set_attribute(Metadata::DICTIONARY, 'attachment_bottom_mm', placement['bottom_mm'])
      entity.set_attribute(Metadata::DICTIONARY, 'attachment_side', placement['side'])
      entity.set_attribute(Metadata::DICTIONARY, 'attachment_clearance_mm', placement['clearance_mm'])
      entity.set_attribute(Metadata::DICTIONARY, 'attachment_span_u_mm', params['width_mm'])
      read(entity)
    end

    def self.clear!(entity)
      metadata = Metadata.read(entity)
      return false unless metadata[MARKER_KEY] == SCHEMA_VERSION

      OWNED_KEYS.each do |key|
        entity.delete_attribute(Metadata::DICTIONARY, key) if entity.respond_to?(:delete_attribute)
      end
      true
    end

    def self.read(entity)
      metadata = Metadata.read(entity)
      return nil unless metadata[MARKER_KEY] == SCHEMA_VERSION

      state = {
        'wall_id' => metadata['wall_id'],
        'offset_mm' => metadata['attachment_offset_mm'],
        'bottom_mm' => metadata['attachment_bottom_mm'],
        'side' => metadata['attachment_side'],
        'clearance_mm' => metadata['attachment_clearance_mm'],
        'span_u_mm' => metadata['attachment_span_u_mm']
      }
      # Keep field validation explicit; a damaged mirror is rejected rather than guessed.
      numbers = %w[offset_mm bottom_mm clearance_mm span_u_mm].map { |key| state[key] }
      valid = state['wall_id'].is_a?(String) && !state['wall_id'].empty? &&
              numbers.all? { |value| value.is_a?(Numeric) && value.finite? } &&
              SIDES.include?(state['side'])
      unless valid
        raise Runtime::BridgeError.new(-32603, 'invalid_response', 'stored WallAttachment metadata is malformed')
      end
      state
    end

    def self.dependents_for(model, wall_id)
      model.entities.to_a.select do |entity|
        metadata = Metadata.read(entity)
        metadata[MARKER_KEY] == SCHEMA_VERSION && metadata['wall_id'] == wall_id
      end
    end

    def self.validate_fit!(attachment, wall_frame, wall_height_mm: nil, object_height_mm: nil)
      offset = attachment['offset_mm']
      span = attachment['span_u_mm']
      if offset < -TOLERANCE_MM || span <= 0 || offset + span > wall_frame.length_mm + TOLERANCE_MM
        raise Runtime::BridgeError.new(-32008, 'constraint_violation',
                                       'wall-attached object must fit within the proposed wall length')
      end
      if wall_height_mm && object_height_mm &&
         (attachment['bottom_mm'] < -TOLERANCE_MM || attachment['bottom_mm'] + object_height_mm > wall_height_mm + TOLERANCE_MM)
        raise Runtime::BridgeError.new(-32008, 'constraint_violation',
                                       'wall-attached object must fit within the proposed wall height')
      end
      true
    end

    def self.wall_transform(wall_frame, wall_thickness_mm, attachment, wall_height_mm: nil, object_height_mm: nil)
      validate_fit!(attachment, wall_frame, wall_height_mm: wall_height_mm, object_height_mm: object_height_mm)
      half = wall_thickness_mm.to_f / 2.0
      positive = attachment['side'] == 'positive_v'
      u = attachment['offset_mm'] + (positive ? 0.0 : attachment['span_u_mm'])
      v = positive ? half + attachment['clearance_mm'] : -half - attachment['clearance_mm']
      origin_mm = wall_frame.local_to_world(u, v, attachment['bottom_mm'])
      x_axis = wall_frame.u_axis.map { |component| positive ? component : -component }
      y_axis = wall_frame.v_axis.map { |component| positive ? component : -component }
      Geom::Transformation.axes(
        Geometry.point_mm(origin_mm, 'wall_attachment.origin_mm'),
        Geom::Vector3d.new(*x_axis), Geom::Vector3d.new(*y_axis), Geom::Vector3d.new(0, 0, 1))
    end

    # Preflight all transforms before Architecture opens its shared Wall operation.
    def self.plan_relocation(model, wall_id, proposed_wall_params)
      frame, wall = Architecture.validate_wall_params!(proposed_wall_params)
      dependents_for(model, wall_id).filter_map do |entity|
        unless entity.respond_to?(:valid?) && entity.valid? &&
               (!entity.respond_to?(:deleted?) || !entity.deleted?)
          raise Runtime::BridgeError.new(-32002, 'target_not_found', 'wall-attached object is deleted or invalid')
        end
        if entity.respond_to?(:locked?) && entity.locked?
          raise Runtime::BridgeError.new(-32008, 'constraint_violation', 'locked wall-attached objects cannot be relocated')
        end
        attachment = read(entity)
        cabinet = FurnitureData.read_params(entity)
        unless cabinet['height_mm'].is_a?(Numeric) && cabinet['height_mm'].finite?
          raise Runtime::BridgeError.new(-32603, 'invalid_response', 'wall-attached Furniture height metadata is malformed')
        end
        transform = wall_transform(frame, wall['thickness_mm'], attachment,
                                   wall_height_mm: wall['height_mm'], object_height_mm: cabinet['height_mm'])
        next if transformations_equal?(entity.transformation, transform)

        [entity, transform]
      end
    end

    def self.transformations_equal?(left, right, tolerance: 1e-8)
      return false unless left.respond_to?(:to_a) && right.respond_to?(:to_a)

      a, b = left.to_a, right.to_a
      a.length == 16 && b.length == 16 && a.zip(b).all? do |first, second|
        first.is_a?(Numeric) && second.is_a?(Numeric) && (first - second).abs <= tolerance
      end
    rescue StandardError
      false
    end
  end
end
