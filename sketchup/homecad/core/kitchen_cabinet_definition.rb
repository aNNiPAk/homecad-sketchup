require_relative 'project_settings'

module HomeCAD
  # Configuration only: all case/drawer panel math and geometry belong to Furniture.
  module KitchenCabinetDefinition
    APPLIANCE_ONLY = %w[dishwasher fridge].freeze
    FIELDS = %w[composition_version panel_thickness_mm back_thickness_mm material_id
      front_material_id shelf_z_mm fronts drawers drawer_layout manufacturing].freeze

    def self.normalize!(model, item, input, preserve_legacy: false)
      if preserve_legacy && !input.key?('composition_version')
        FIELDS.each { |key| item[key] = input[key] if input.key?(key) }
        for_module(model, item)
        return item
      end
      return item if APPLIANCE_ONLY.include?(item['type']) && (input.keys & (FIELDS - %w[material_id front_material_id])).empty?
      if APPLIANCE_ONLY.include?(item['type'])
        Architecture.constraint!('appliance-only modules cannot configure a Cabinet')
      end
      defaults = ProjectSettings.read(model)['values']
      item['composition_version'] = input.fetch('composition_version', 1)
      Primitives.invalid!('composition_version must be 1') unless item['composition_version'] == 1
      %w[panel_thickness_mm back_thickness_mm material_id front_material_id].each do |key|
        fallback = key == 'back_thickness_mm' && item['type'] == 'sink' ? 0 : defaults[key]
        item[key] = input.fetch(key, fallback)
      end
      %w[shelf_z_mm fronts drawers drawer_layout manufacturing].each do |key|
        item[key] = input[key] if input.key?(key)
      end
      configuration = for_module(model, item)
      %w[panel_thickness_mm back_thickness_mm material_id front_material_id shelf_z_mm fronts drawers manufacturing].each do |key|
        item[key] = configuration[key] if item.key?(key)
      end
      item
    end

    def self.for_module(model, item)
      return nil if APPLIANCE_ONLY.include?(item['type'])
      unless item.key?('composition_version')
        return nil if %w[hob oven].include?(item['type'])
        return Furniture.validate_params!(model, item.slice('width_mm','depth_mm','height_mm',
          'material_id','front_material_id','manufacturing').merge('detail_level'=>'construction'))
      end
      panel = item.fetch('panel_thickness_mm', 18.0)
      back = Geometry.finite_number(item.fetch('back_thickness_mm', 4.0), 'back_thickness_mm')
      width = item['width_mm']; height = item['height_mm']
      panel = Geometry.positive_length(panel, 'panel_thickness_mm')
      fronts = item.fetch('fronts', default_fronts(item, panel))
      fronts = Furniture.validate_fronts!(fronts, { 'width_mm'=>width,
        'height_mm'=>height, 'panel_thickness_mm'=>panel })
      # Module depth is the total outer envelope, including configured fronts.
      front_depth = fronts.map { |front| front.fetch('thickness_mm', panel) }.max || 0
      depth = item['depth_mm'] - front_depth
      shelves = item.fetch('shelf_z_mm', case item['type']
        when 'base_shelves', 'wall_shelves' then [(height - panel) / 2.0]
        when 'tall_storage' then [0.25, 0.5, 0.75].map { |ratio| (height-panel)*ratio }
        else []
      end)
      params = item.slice('material_id', 'front_material_id', 'manufacturing').merge(
        'width_mm'=>width, 'depth_mm'=>depth, 'height_mm'=>height,
        'panel_thickness_mm'=>panel, 'back_thickness_mm'=>back,
        'shelf_z_mm'=>shelves, 'fronts'=>fronts, 'detail_level'=>'construction')
      params['top_panel'] = false if %w[sink hob].include?(item['type'])
      if item['type'] == 'base_drawers'
        Architecture.constraint!('use drawers or drawer_layout, not both') if item.key?('drawers') && item.key?('drawer_layout')
        params['drawers'] = item.fetch('drawers', default_drawers(item, params))
        Architecture.constraint!('base_drawers requires at least one drawer') unless params['drawers'].is_a?(Array) && params['drawers'].any?
      elsif item.key?('drawers') || item.key?('drawer_layout')
        Architecture.constraint!('drawers and drawer_layout require base_drawers')
      end
      Furniture.validate_params!(model, params, allow_unknown_drawer_sku: true)
    end

    def self.layout(item)
      input = item.fetch('drawer_layout', {})
      Primitives.invalid!('drawer_layout must be an object') unless input.is_a?(Hash)
      Primitives.check_keys!(input, %w[count gap_mm side_thickness_mm base_thickness_mm slide])
      count = input.fetch('count', 2)
      Primitives.invalid!('drawer_layout.count must be 1..16') unless count.is_a?(Integer) && (1..16).cover?(count)
      gap = Geometry.finite_number(input.fetch('gap_mm', 2), 'drawer_layout.gap_mm')
      Architecture.constraint!('drawer_layout.gap_mm must be nonnegative') if gap.negative?
      Architecture.constraint!('drawer layout leaves no front height') if gap >= item['height_mm'] / count.to_f
      [input, count, gap]
    end

    def self.default_fronts(item, panel)
      if item['type'] == 'base_drawers'
        _, count, gap = layout(item)
        segment = item['height_mm'] / count.to_f
        count.times.map do |i|
          { 'key'=>"drawer_#{i}", 'kind'=>'drawer_front', 'x_mm'=>0,
            'z_mm'=>i*segment+gap/2, 'width_mm'=>item['width_mm'],
            'height_mm'=>segment-gap, 'thickness_mm'=>panel }
        end
      elsif item['type'] == 'wall_lift_front'
        [{ 'key'=>'lift_concept', 'kind'=>'fixed_panel', 'x_mm'=>0, 'z_mm'=>0,
          'width_mm'=>item['width_mm'], 'height_mm'=>item['height_mm'], 'thickness_mm'=>panel }]
      else []
      end
    end

    def self.default_drawers(item, params)
      spec, _, gap = layout(item)
      panel = params['panel_thickness_mm']
      params['fronts'].map.with_index do |front, i|
        bottom = [front['z_mm'] + gap, panel].max
        top = [front['z_mm']+front['height_mm']-gap, params['height_mm']-panel].min
        depth = params['depth_mm'] - params['back_thickness_mm']
        { 'key'=>"drawer_#{i}", 'front_key'=>front['key'], 'bottom_mm'=>bottom,
          'height_mm'=>top-bottom, 'depth_mm'=>depth,
          'side_thickness_mm'=>spec.fetch('side_thickness_mm', panel),
          'base_thickness_mm'=>spec.fetch('base_thickness_mm', 6),
          'slide'=>spec.fetch('slide', { 'family_id'=>HardwareCatalog::FAMILY_ID,
            'sku'=>nil, 'nominal_length_mm'=>depth, 'side_clearance_mm'=>10 }) }
      end
    end

    def self.build!(model, group, item)
      cabinet = for_module(model, item)
      if cabinet
        Furniture.build_geometry!(group, cabinet)
      else
        # A plain concept appliance volume, without counterfeit carcass panels.
        face = group.entities.add_face([[0,0,0], [item['width_mm'],0,0],
          [item['width_mm'],item['depth_mm'],0], [0,item['depth_mm'],0]].map { |p| Geometry.point_mm(p, 'appliance') })
        Primitives.geometry_created!(face, 'SketchUp could not create appliance volume')
        Furniture.extrude_to_positive_z!(face, Units.mm_to_internal(item['height_mm']), 'appliance')
      end
    end
  end
end
