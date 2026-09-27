module HomeCAD
  module FurniturePresets
    PRESETS = {
      'base_open.v1' => { 'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
                          'detail_level' => 'construction', 'shelf_z_mm' => [] },
      'base_shelves.v1' => { 'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
                             'detail_level' => 'construction', 'shelf_z_mm' => [350] },
      'wall_open.v1' => { 'width_mm' => 600, 'depth_mm' => 350, 'height_mm' => 720,
                          'detail_level' => 'construction', 'shelf_z_mm' => [] },
      'tall_shelves.v1' => { 'width_mm' => 600, 'depth_mm' => 600, 'height_mm' => 2100,
                             'detail_level' => 'construction', 'shelf_z_mm' => [500, 1000, 1500] }
    }.freeze
    INHERITED = %w[panel_thickness_mm back_thickness_mm material_id front_material_id].freeze

    def self.list
      { 'presets' => PRESETS.map { |id, values| { 'id' => id, 'version' => 1,
        'parameters' => values, 'inherited_fields' => INHERITED } } }
    end

    def self.get(id)
      values = PRESETS[id]
      raise Runtime::BridgeError.new(-32002, 'target_not_found', "unknown Furniture preset: #{id}") unless values

      { 'id' => id, 'version' => 1, 'parameters' => values,
        'inherited_fields' => INHERITED }
    end

    def self.resolve(model, id, overrides)
      get(id)
      ProjectSettings.invalid!('overrides must be an object') unless overrides.is_a?(Hash)
      allowed = Furniture::CREATE_KEYS
      ProjectSettings.invalid!("unsupported preset overrides: #{(overrides.keys - allowed).join(', ')}") unless
        (overrides.keys - allowed).empty?
      defaults = ProjectSettings.read(model)['values']
      inherited = INHERITED - overrides.keys
      params = defaults.slice(*INHERITED).merge(PRESETS.fetch(id)).merge(overrides)
      if params['placement'].is_a?(Hash) && params['placement']['mode'] == 'wall' &&
         !params['placement'].key?('clearance_mm')
        params['placement'] = params['placement'].merge('clearance_mm' => defaults['cabinet_wall_clearance_mm'])
        inherited << 'cabinet_wall_clearance_mm'
      end
      source = { 'preset_id' => id, 'preset_version' => 1,
        'overrides' => overrides, 'inherited_fields' => inherited }
      [params, source]
    end

    def self.rederive(model, source, settings)
      id = source.fetch('preset_id')
      get(id)
      overrides = source.fetch('overrides')
      inherited = source.fetch('inherited_fields')
      values = settings.slice(*(INHERITED & inherited)).merge(PRESETS.fetch(id)).merge(overrides)
      if inherited.include?('cabinet_wall_clearance_mm')
        placement = values['placement']
        values['placement'] = placement.merge('clearance_mm' => settings['cabinet_wall_clearance_mm'])
      end
      Furniture.validate_params!(model, values)
    end
  end
end
