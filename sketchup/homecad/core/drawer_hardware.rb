module HomeCAD
  module DrawerHardware
    MAX_DRAWERS = 16
    TOLERANCE_MM = 0.01
    INPUT_KEYS = %w[key front_key bottom_mm height_mm depth_mm side_thickness_mm
                    base_thickness_mm slide].freeze

    def self.normalize!(params)
      drawers = params['drawers']
      invalid!('drawers must be an array of at most 16 entries') unless
        drawers.is_a?(Array) && drawers.length <= MAX_DRAWERS
      fronts = params['fronts'].to_h { |front| [front['key'], front] }
      normalized = drawers.map do |item|
        invalid!('drawer must be an object') unless item.is_a?(Hash)
        Primitives.check_keys!(item, INPUT_KEYS)
        key = Furniture.validate_identifier(item['key'], 'drawers.key')
        invalid!('drawers.key is required') unless key
        front_key = item['front_key']
        front = fronts[front_key]
        constraint!("drawer #{key} must reference a drawer_front") unless front && front['kind'] == 'drawer_front'
        constraint!("drawer #{key} requires a full-width front in M5.7") unless
          front['x_mm'].abs <= TOLERANCE_MM &&
          (front['width_mm'] - params['width_mm']).abs <= TOLERANCE_MM

        bottom = Geometry.finite_number(item['bottom_mm'], "drawers.#{key}.bottom_mm")
        height = Geometry.positive_length(item['height_mm'], "drawers.#{key}.height_mm")
        depth = Geometry.positive_length(item['depth_mm'], "drawers.#{key}.depth_mm")
        side = Geometry.positive_length(item['side_thickness_mm'], "drawers.#{key}.side_thickness_mm")
        base = Geometry.positive_length(item['base_thickness_mm'], "drawers.#{key}.base_thickness_mm")
        constraint!("drawer #{key} must fit inside the Cabinet and its front") if
          bottom < params['panel_thickness_mm'] - TOLERANCE_MM ||
          bottom + height > params['height_mm'] - params['panel_thickness_mm'] + TOLERANCE_MM ||
          bottom < front['z_mm'] - TOLERANCE_MM ||
          bottom + height > front['z_mm'] + front['height_mm'] + TOLERANCE_MM ||
          depth > params['depth_mm'] - params['back_thickness_mm'] + TOLERANCE_MM
        constraint!("drawer #{key} needs room for its base and panels") if
          height <= base + TOLERANCE_MM || depth <= 2 * side + TOLERANCE_MM

        slide = item['slide']
        invalid!("drawers.#{key}.slide must be an object") unless slide.is_a?(Hash)
        Primitives.check_keys!(slide, %w[family_id sku nominal_length_mm side_clearance_mm])
        family = HardwareCatalog.family!(slide['family_id'])
        constraint!("hardware family is not a wood-drawer slide pair") unless
          family['id'] == HardwareCatalog::FAMILY_ID && family['unit'] == 'pair'
        sku = Furniture.validate_identifier(slide['sku'], "drawers.#{key}.slide.sku")
        invalid!("drawers.#{key}.slide.sku is required") unless sku
        nominal = Geometry.positive_length(slide['nominal_length_mm'],
          "drawers.#{key}.slide.nominal_length_mm")
        clearance = Geometry.positive_length(slide['side_clearance_mm'],
          "drawers.#{key}.slide.side_clearance_mm")
        outer_width = params['width_mm'] - 2 * params['panel_thickness_mm'] - 2 * clearance
        constraint!("drawer #{key} does not fit between its slides") if outer_width <= 2 * side + TOLERANCE_MM
        constraint!("drawer #{key} slide is longer than available depth") if
          nominal > depth + TOLERANCE_MM || nominal > params['depth_mm'] - params['back_thickness_mm'] + TOLERANCE_MM
        params['shelf_z_mm'].each do |z|
          constraint!("drawer #{key} intersects a shelf") if
            [bottom, z].max < [bottom + height, z + params['panel_thickness_mm']].min - TOLERANCE_MM
        end
        { 'key' => key, 'front_key' => front_key, 'bottom_mm' => bottom,
          'height_mm' => height, 'depth_mm' => depth,
          'side_thickness_mm' => side, 'base_thickness_mm' => base,
          'slide' => { 'family_id' => family['id'], 'sku' => sku,
            'nominal_length_mm' => nominal, 'side_clearance_mm' => clearance } }
      end
      invalid!('drawer keys and front keys must be unique') unless
        normalized.map { |item| item['key'] }.uniq.length == normalized.length &&
        normalized.map { |item| item['front_key'] }.uniq.length == normalized.length
      normalized.combination(2) do |a, b|
        constraint!('drawers may not overlap') if
          [a['bottom_mm'], b['bottom_mm']].max <
          [a['bottom_mm'] + a['height_mm'], b['bottom_mm'] + b['height_mm']].min - TOLERANCE_MM
      end
      params['drawers'] = normalized
    end

    def self.parts(params)
      panel = params['panel_thickness_mm']; width = params['width_mm']; cabinet_depth = params['depth_mm']
      params.fetch('drawers', []).flat_map do |drawer|
        key = drawer['key']; side = drawer['side_thickness_mm']; base = drawer['base_thickness_mm']
        clearance = drawer['slide']['side_clearance_mm']
        outer = width - 2 * panel - 2 * clearance
        x = panel + clearance; y = cabinet_depth - drawer['depth_mm']; z = drawer['bottom_mm']
        inner = outer - 2 * side; inner_depth = drawer['depth_mm'] - 2 * side
        side_height = drawer['height_mm'] - base
        prefix = "drawer:#{key}"
        [
          part("#{prefix}/base", 'drawer_base', outer, drawer['depth_mm'], base, [x, y, z]),
          part("#{prefix}/left_side", 'drawer_side', drawer['depth_mm'], side_height,
            side, [x, y, z + base]),
          part("#{prefix}/right_side", 'drawer_side', drawer['depth_mm'], side_height,
            side, [x + outer - side, y, z + base]),
          part("#{prefix}/back", 'drawer_end', inner, side_height,
            side, [x + side, y, z + base]),
          part("#{prefix}/front", 'drawer_end', inner, side_height,
            side, [x + side, y + drawer['depth_mm'] - side, z + base])
        ]
      end
    end

    def self.part(key, kind, width, height, thickness, origin)
      { 'part_key' => key, 'part_kind' => kind, 'quantity' => 1,
        'width_mm' => width, 'height_mm' => height, 'thickness_mm' => thickness,
        'origin_mm' => origin }
    end

    def self.hardware_records(params, object_id, type, prefix: nil)
      params.fetch('drawers', []).map do |drawer|
        family = HardwareCatalog.family!(drawer['slide']['family_id'])
        { 'record_kind' => 'hardware', 'source_object_id' => object_id,
          'source_type' => type,
          'part_key' => [prefix, "drawer:#{drawer['key']}/slide_pair"].compact.join('/'),
          'part_kind' => 'drawer_slide_pair',
          'quantity' => family['quantity_per_assembly'], 'unit' => family['unit'],
          'length_mm' => nil, 'width_mm' => nil, 'thickness_mm' => nil,
          'material_id' => nil, 'grain_axis' => nil, 'edge_band' => nil,
          'sku' => drawer['slide']['sku'], 'family_id' => drawer['slide']['family_id'],
          'front_key' => drawer['front_key'],
          'nominal_length_mm' => drawer['slide']['nominal_length_mm'] }
      end
    end

    def self.invalid!(message) = Primitives.invalid!(message)
    def self.constraint!(message) = Furniture.constraint!(message)
  end
end
