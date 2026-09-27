module HomeCAD
  module KitchenVariants
    MAX_CUTOUTS = 16
    CUTOUT_BORDER_MM = 10.0
    EDGES = %w[length_start length_end width_start width_end].freeze

    def self.normalize!(model, params, input, overrides: {})
      top = input.key?('countertop') ? input['countertop'] : { 'enabled' => false }
      invalid!('countertop must be an object') unless top.is_a?(Hash)
      Primitives.check_keys!(top, %w[enabled thickness_mm first_end second_end cutouts material_id])
      enabled = top.fetch('enabled', true)
      invalid!('countertop.enabled must be boolean') unless [true, false].include?(enabled)
      if enabled
        thickness = Geometry.positive_length(top.fetch('thickness_mm', 38), 'countertop.thickness_mm')
        constraint!('countertop thickness exceeds 100 mm') if thickness > 100
        ends = %w[first_end second_end].to_h do |key|
          value = top.fetch(key, { 'style' => 'square' })
          invalid!("countertop.#{key} must be an object") unless value.is_a?(Hash)
          Primitives.check_keys!(value, %w[style bevel_mm])
          style = value.fetch('style', 'square')
          invalid!("countertop.#{key}.style must be square or bevel") unless %w[square bevel].include?(style)
          if style == 'bevel'
            bevel = Geometry.positive_length(value['bevel_mm'], "countertop.#{key}.bevel_mm")
            [key, { 'style' => style, 'bevel_mm' => bevel }]
          else
            invalid!("countertop.#{key}.bevel_mm requires bevel style") if value.key?('bevel_mm')
            [key, { 'style' => style }]
          end
        end
        cutouts = top.fetch('cutouts', [])
        invalid!("countertop.cutouts must have at most #{MAX_CUTOUTS} entries") unless
          cutouts.is_a?(Array) && cutouts.length <= MAX_CUTOUTS
        normalized = cutouts.map.with_index do |item, index|
          invalid!("cutouts[#{index}] must be an object") unless item.is_a?(Hash)
          Primitives.check_keys!(item, %w[key leg_key offset_mm front_mm width_mm depth_mm])
          key = item['key']; leg_key = item['leg_key']
          invalid!('cutout key must be nonempty and at most 64 characters') unless
            key.is_a?(String) && !key.empty? && key.length <= 64
          invalid!('cutout leg_key must identify a Kitchen leg') unless params['legs'].any? { |leg| leg['key'] == leg_key }
          { 'key' => key, 'leg_key' => leg_key,
            'offset_mm' => Geometry.finite_number(item['offset_mm'], "cutouts[#{index}].offset_mm"),
            'front_mm' => Geometry.finite_number(item['front_mm'], "cutouts[#{index}].front_mm"),
            'width_mm' => Geometry.positive_length(item['width_mm'], "cutouts[#{index}].width_mm"),
            'depth_mm' => Geometry.positive_length(item['depth_mm'], "cutouts[#{index}].depth_mm") }
        end
        invalid!('cutout keys must be unique') unless normalized.map { |item| item['key'] }.uniq.length == normalized.length
        material = Furniture.validate_identifier(top['material_id'], 'countertop.material_id')
        params['countertop'] = { 'enabled' => true, 'thickness_mm' => thickness,
          'first_end' => ends['first_end'], 'second_end' => ends['second_end'],
          'cutouts' => normalized, 'material_id' => material }
        params['legs'].each do |leg|
          wall = overrides[leg['wall_id']] || Architecture.wall_entity!(model,
            { 'homecad_id' => leg['wall_id'] })[1]
          constraint!('countertop exceeds Wall height') if params['bottom_mm'] +
            params['height_mm'] + thickness > wall['height_mm'] + Kitchen::TOLERANCE_MM
        end
      else
        invalid!('disabled countertop accepts only enabled=false') unless top.keys == ['enabled']
        params['countertop'] = { 'enabled' => false }
      end
      panels = input.fetch('panels', {})
      invalid!('panels must be an object') unless panels.is_a?(Hash)
      Primitives.check_keys!(panels, %w[first second])
      params['panels'] = panels.to_h do |key, value|
        invalid!("panels.#{key} must be an object") unless value.is_a?(Hash)
        Primitives.check_keys!(value, %w[thickness_mm material_id grain_axis edge_band sku])
        thickness = Geometry.positive_length(value['thickness_mm'], "panels.#{key}.thickness_mm")
        constraint!('end-panel thickness exceeds 100 mm') if thickness > 100
        material = Furniture.validate_identifier(value['material_id'], "panels.#{key}.material_id")
        sku = Furniture.validate_identifier(value['sku'], "panels.#{key}.sku")
        grain = value['grain_axis']
        invalid!('panel grain_axis is invalid') unless grain.nil? || %w[length width none].include?(grain)
        edges = value.fetch('edge_band', {})
        invalid!('panel edge_band must be an object') unless edges.is_a?(Hash)
        Primitives.check_keys!(edges, EDGES)
        normalized_edges = EDGES.to_h do |side|
          [side, Furniture.validate_identifier(edges[side], "panels.#{key}.edge_band.#{side}")]
        end
        leg = params['legs'][key == 'first' ? 0 : 1]
        positions = leg['positions']
        last = positions.last
        start = if leg['corner_at_start']
          last['offset_mm'] + last['width_mm'] + leg['filler_mm']
        else
          positions.first['offset_mm'] - thickness
        end
        constraint!('end panel does not fit in the requested Wall interval') if
          start < leg['start_mm'] - Kitchen::TOLERANCE_MM ||
          start + thickness > leg['end_mm'] + Kitchen::TOLERANCE_MM
        [key, { 'thickness_mm' => thickness, 'material_id' => material,
          'grain_axis' => grain, 'edge_band' => normalized_edges, 'sku' => sku,
          'offset_mm' => start }]
      end
      footprint(model, params, overrides: overrides) if params.dig('countertop', 'enabled')
      params
    end

    def self.footprint(model, params, overrides: {})
      first, second = params['legs']
      wall_data = [first, second].map do |leg|
        wall = overrides[leg['wall_id']] || Architecture.wall_entity!(model,
          { 'homecad_id' => leg['wall_id'] })[1]
        Architecture.validate_wall_params!(wall)
      end
      d1 = first['corner_at_start'] ? wall_data[0][0].u_axis : wall_data[0][0].u_axis.map { |v| -v }
      d2 = second['corner_at_start'] ? wall_data[1][0].u_axis : wall_data[1][0].u_axis.map { |v| -v }
      half1 = wall_data[0][1]['thickness_mm'] / 2.0
      half2 = wall_data[1][1]['thickness_mm'] / 2.0
      origin = params['corner_point_mm'].each_index.map do |i|
        params['corner_point_mm'][i] + d1[i] * half2 + d2[i] * half1
      end
      legs = [first, second]
      lengths = legs.each_with_index.map do |leg, index|
        max_end = leg['positions'].map { |position| position['offset_mm'] + position['width_mm'] }.max
        panel = params.fetch('panels', {})[index.zero? ? 'first' : 'second']
        max_end = [max_end, panel['offset_mm'] + panel['thickness_mm']].max if panel
        if leg['corner_at_start']
          max_end += leg['filler_mm']
          max_end - (index == 0 ? half2 : half1)
        else
          wall_length = wall_data[index][0].length_mm
          first_start = panel ? [leg['positions'].first['offset_mm'], panel['offset_mm']].min :
            leg['positions'].first['offset_mm']
          wall_length - first_start - (index == 0 ? half2 : half1)
        end
      end
      depth1 = first['modules'].map { |item| item['depth_mm'] }.max + 20
      depth2 = second['modules'].map { |item| item['depth_mm'] }.max + 20
      l1, l2 = lengths
      constraint!('countertop arms are too short for a single L footprint') if
        l1 <= depth2 + CUTOUT_BORDER_MM || l2 <= depth1 + CUTOUT_BORDER_MM
      top = params['countertop']
      first_end = top['first_end']; second_end = top['second_end']
      first_bevel = first_end['style'] == 'bevel' ? first_end['bevel_mm'] : 0.0
      second_bevel = second_end['style'] == 'bevel' ? second_end['bevel_mm'] : 0.0
      constraint!('first countertop bevel exceeds arm width') if first_bevel >= [depth1, l1 - depth2].min
      constraint!('second countertop bevel exceeds arm width') if second_bevel >= [depth2, l2 - depth1].min
      polygon = [[0.0, 0.0], [l1, 0.0]]
      polygon << [l1, depth1 - first_bevel] if first_bevel.positive?
      polygon << [l1 - first_bevel, depth1]
      polygon << [depth2, depth1]
      polygon << [depth2, l2 - second_bevel] if second_bevel.positive?
      polygon << [depth2 - second_bevel, l2]
      polygon << [0.0, l2]
      holes = top['cutouts'].map do |cutout|
        first_leg = cutout['leg_key'] == first['key']
        x0 = first_leg ? cutout['offset_mm'] - half2 : cutout['front_mm']
        y0 = first_leg ? cutout['front_mm'] : cutout['offset_mm'] - half1
        x1 = x0 + (first_leg ? cutout['width_mm'] : cutout['depth_mm'])
        y1 = y0 + (first_leg ? cutout['depth_mm'] : cutout['width_mm'])
        if first_leg
          constraint!('cutout must lie within the first arm beyond the shared corner') unless
            x0 >= depth2 + CUTOUT_BORDER_MM && x1 <= l1 - CUTOUT_BORDER_MM &&
            y0 >= CUTOUT_BORDER_MM && y1 <= depth1 - CUTOUT_BORDER_MM
        else
          constraint!('cutout must lie within the second arm beyond the shared corner') unless
            y0 >= depth1 + CUTOUT_BORDER_MM && y1 <= l2 - CUTOUT_BORDER_MM &&
            x0 >= CUTOUT_BORDER_MM && x1 <= depth2 - CUTOUT_BORDER_MM
        end
        [x0, y0, x1, y1]
      end
      holes.combination(2) do |a, b|
        constraint!('countertop cutouts overlap') if
          [a[0], b[0]].max < [a[2], b[2]].min - Kitchen::TOLERANCE_MM &&
          [a[1], b[1]].max < [a[3], b[3]].min - Kitchen::TOLERANCE_MM
      end
      { 'origin_mm' => origin, 'x_axis' => d1, 'y_axis' => d2,
        'polygon_mm' => polygon, 'holes_mm' => holes,
        'arm_lengths_mm' => lengths, 'arm_depths_mm' => [depth1, depth2] }
    end

    def self.build_countertop!(model, root, params, descriptor, run_id)
      shape = footprint(model, params)
      group = root.entities.add_group
      group.name = 'countertop'
      KitchenData.write_child(group, record: params['semantic_objects'].fetch('countertop'),
        descriptor: descriptor, run_id: run_id, wall_id: params['legs'][0]['wall_id'])
      group.transformation = CornerKitchen.axes(shape['origin_mm'], shape['x_axis'], shape['y_axis'])
      z = params['bottom_mm'] + params['height_mm']
      points = shape['polygon_mm'].map { |x, y| Geometry.point_mm([x, y, z], 'countertop.outer') }
      face = group.entities.add_face(points)
      Primitives.geometry_created!(face, 'SketchUp could not create continuous L countertop')
      shape['holes_mm'].each do |x0, y0, x1, y1|
        loop_points = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]].map do |x, y|
          Geometry.point_mm([x, y, z], 'countertop.cutout')
        end
        inner = group.entities.add_face(loop_points)
        Primitives.geometry_created!(inner, 'SketchUp could not create countertop cutout')
        inner.erase!
      end
      expected_loops = shape['holes_mm'].length + 1
      if face.respond_to?(:loops) && face.loops.length != expected_loops
        raise Runtime::BridgeError.new(-32009, 'geometry_error', 'countertop cutout loop count is incorrect')
      end
      distance = Units.mm_to_internal(params['countertop']['thickness_mm'])
      face.pushpull(face.normal.z.positive? ? distance : -distance)
      group
    end

    def self.build_panel!(model, root, params, key, descriptor, run_id)
      panel = params['panels'].fetch(key)
      leg = params['legs'][key == 'first' ? 0 : 1]
      frame, wall = Architecture.validate_wall_params!(Architecture.wall_entity!(model,
        { 'homecad_id' => leg['wall_id'] })[1])
      group = root.entities.add_group
      group.name = "panel:#{key}"
      KitchenData.write_child(group, record: params['semantic_objects'].fetch("panel:#{key}"),
        descriptor: descriptor, run_id: run_id, wall_id: leg['wall_id'])
      attachment = { 'wall_id' => leg['wall_id'], 'offset_mm' => panel['offset_mm'],
        'bottom_mm' => params['bottom_mm'], 'side' => leg['side'],
        'clearance_mm' => leg['clearance_mm'], 'span_u_mm' => panel['thickness_mm'],
        'span_z_mm' => params['height_mm'] }
      group.transformation = WallAttachment.wall_transform(frame, wall['thickness_mm'],
        attachment, wall_height_mm: wall['height_mm'])
      depth = leg['modules'].map { |item| item['depth_mm'] }.max
      Kitchen.box!(group, 'end_panel', 0, 0, 0, panel['thickness_mm'], depth, params['height_mm'])
      group
    end

    def self.invalid!(message) = Primitives.invalid!(message)
    def self.constraint!(message) = Architecture.constraint!(message)
  end
end
