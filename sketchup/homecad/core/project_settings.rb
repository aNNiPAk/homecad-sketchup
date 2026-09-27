require 'json'

module HomeCAD
  module ProjectSettings
    DICTIONARY = 'HomeCAD'.freeze
    KEY = 'project_settings_json'.freeze
    REVISION_KEY = 'project_settings_revision'.freeze
    DEFAULTS = {
      'panel_thickness_mm' => 18.0,
      'back_thickness_mm' => 4.0,
      'cabinet_wall_clearance_mm' => 0.0,
      'material_id' => nil,
      'front_material_id' => nil
    }.freeze

    def self.read(model)
      raw = model.get_attribute(DICTIONARY, KEY)
      stored = raw.nil? ? {} : JSON.parse(raw)
      raise JSON::ParserError unless stored.is_a?(Hash)

      { 'values' => validate(DEFAULTS.merge(stored)),
        'revision' => model.get_attribute(DICTIONARY, REVISION_KEY, 0).to_i }
    rescue JSON::ParserError
      raise Runtime::BridgeError.new(-32603, 'invalid_response', 'stored project settings are malformed')
    end

    def self.validate(values)
      unknown = values.keys - DEFAULTS.keys
      invalid!("unsupported project settings: #{unknown.join(', ')}") unless unknown.empty?
      normalized = values.dup
      %w[panel_thickness_mm].each do |key|
        normalized[key] = Geometry.positive_length(values[key], key)
      end
      %w[back_thickness_mm cabinet_wall_clearance_mm].each do |key|
        normalized[key] = Geometry.finite_number(values[key], key)
        invalid!("#{key} must be nonnegative") if normalized[key].negative?
      end
      %w[material_id front_material_id].each do |key|
        value = values[key]
        invalid!("#{key} must be null or a nonempty identifier up to 128 characters") unless
          value.nil? || (value.is_a?(String) && !value.strip.empty? && value.length <= 128)
      end
      normalized
    end

    def self.write!(model, values, revision)
      model.set_attribute(DICTIONARY, KEY, JSON.generate(values))
      model.set_attribute(DICTIONARY, REVISION_KEY, revision)
    end

    def self.update(model, changes)
      invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      current = read(model)
      proposed = validate(current['values'].merge(changes))
      return MutationResult.success(operation: 'update_project_settings',
        revision: current['revision']) if proposed == current['values']

      dependents = model.entities.to_a.filter_map do |entity|
        next unless Metadata.read(entity)['type'] == 'furniture.cabinet'

        source = FurnitureData.read_source(entity)
        next unless source['preset_id']

        next unless (source['inherited_fields'] & changes.keys).any?

        Furniture.require_mutable!(entity)
        params = FurniturePresets.rederive(model, source, proposed)
        new_transform = Furniture.transformation(Furniture.frame_for(model, params))
        old_params = FurnitureData.read_params(entity)
        next if FurnitureData.canonical(params) == FurnitureData.canonical(old_params)

        [entity, old_params, params, new_transform]
      end
      Operation.run('Update HomeCAD project settings', model: model) do
        write!(model, proposed, current['revision'] + 1)
        dependents.each do |entity, before, params, transformation|
          FurnitureData.write(entity, params: params)
          entity.transformation = transformation unless
            WallAttachment.transformations_equal?(entity.transformation, transformation)
          if %w[width_mm depth_mm height_mm panel_thickness_mm back_thickness_mm shelf_z_mm fronts detail_level].any? { |key| before[key] != params[key] }
            Furniture.build_geometry!(entity, params)
          end
          Metadata.increment_revision!(entity)
        end
        MutationResult.success(operation: 'update_project_settings',
          updated: dependents.map { |entry| Furniture.serialize_entity(entry[0]) },
          revision: current['revision'] + 1)
      end
    end

    def self.invalid!(message)
      raise Runtime::BridgeError.new(-32602, 'invalid_request', message)
    end
  end
end
