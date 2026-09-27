module HomeCAD
  # Analytic, read-only clearance checks for upright HomeCAD domain volumes.
  # Box coordinates are millimeters; X/Y axes are horizontal unit vectors.
  module ServiceZones
    TOLERANCE_MM = 0.01
    MAX_FINDINGS = 100
    DIRECTIONS = %w[u_start_mm u_end_mm front_mm back_mm top_mm bottom_mm].freeze

    def self.box(origin, x_axis, y_axis, limits)
      { origin: origin, x: x_axis, y: y_axis, limits: limits }
    end

    def self.frame_from_wall(wall_params, side: nil)
      frame, normalized = Architecture.validate_wall_params!(wall_params)
      sign = side == 'negative_v' ? -1.0 : 1.0
      half = side ? sign * normalized['thickness_mm'] / 2.0 : 0.0
      origin = frame.local_to_world(0, half, 0)
      [origin, frame.u_axis, frame.v_axis.map { |part| part * sign }]
    end

    def self.frame_from_transform(transformation)
      matrix = transformation.to_a
      origin = matrix[12, 3].map { |value| Units.internal_to_mm(value) }
      [origin, matrix[0, 3], matrix[4, 3]]
    end

    def self.point_xy(box, u, v)
      origin = box[:origin]
      [origin[0] + box[:x][0] * u + box[:y][0] * v,
       origin[1] + box[:x][1] * u + box[:y][1] * v]
    end

    def self.world_bounds(box)
      return box[:aabb] if box[:aabb]

      u0, u1, v0, v1, z0, z1 = box[:limits]
      points = [u0, u1].product([v0, v1]).map { |u, v| point_xy(box, u, v) }
      box[:aabb] = [[points.map(&:first).min, points.map(&:first).max],
       [points.map(&:last).min, points.map(&:last).max],
       [box[:origin][2] + z0, box[:origin][2] + z1]]
    end

    def self.overlap?(left, right)
      aabb_left = world_bounds(left); aabb_right = world_bounds(right)
      return false unless 3.times.all? do |index|
        [aabb_left[index][0], aabb_right[index][0]].max <
          [aabb_left[index][1], aabb_right[index][1]].min - TOLERANCE_MM
      end

      axes = [left[:x], left[:y], right[:x], right[:y]]
      axes.all? do |axis|
        ranges = [left, right].map do |item|
          u0, u1, v0, v1 = item[:limits]
          projections = [u0, u1].product([v0, v1]).map do |u, v|
            point = point_xy(item, u, v)
            point[0] * axis[0] + point[1] * axis[1]
          end
          [projections.min, projections.max]
        end
        [ranges[0][0], ranges[1][0]].max < [ranges[0][1], ranges[1][1]].min - TOLERANCE_MM
      end
    end

    def self.slabs(bounds, clearance)
      u0, u1, v0, v1, z0, z1 = bounds
      start_gap = clearance.fetch('u_start_mm', 0); end_gap = clearance.fetch('u_end_mm', 0)
      front = clearance.fetch('front_mm', 0); back = clearance.fetch('back_mm', 0)
      top = clearance.fetch('top_mm', 0); bottom = clearance.fetch('bottom_mm', 0)
      {
        'u_start' => [u0 - start_gap, u0, v0 - back, v1 + front, z0 - bottom, z1 + top],
        'u_end' => [u1, u1 + end_gap, v0 - back, v1 + front, z0 - bottom, z1 + top],
        'front' => [u0, u1, v1, v1 + front, z0 - bottom, z1 + top],
        'back' => [u0, u1, v0 - back, v0, z0 - bottom, z1 + top],
        'top' => [u0, u1, v0, v1, z1, z1 + top],
        'bottom' => [u0, u1, v0, v1, z0 - bottom, z0]
      }.reject { |_direction, values| values.each_slice(2).any? { |first, second| second - first <= TOLERANCE_MM } }
    end

    def self.obstacles(model, exclude_run_id: nil)
      model.entities.to_a.filter_map do |entity|
        data = Metadata.read(entity)
        id = data['homecad_id']
        next unless id && id != exclude_run_id

        type = data['type']
        boxes = case type
                when 'architecture.wall'
                  params = ArchitectureData.read_params(entity)
                  frame = frame_from_wall(params)
                  cuts = Architecture.hosted_for(model, id).map do |host|
                    ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type'])
                  end
                  wall = Architecture.validate_wall_params!(params).last
                  length = WallFrame.build(params['start_mm'], params['end_mm']).length_mm
                  Architecture.wall_occupied_cells(length, wall['thickness_mm'], wall['height_mm'], cuts)
                    .map { |limits| box(*frame, limits) }
                when 'architecture.column', 'furniture.cabinet'
                  params = type == 'architecture.column' ? ArchitectureData.read_params(entity) : FurnitureData.read_params(entity)
                  frame = if type == 'architecture.column'
                    radians = params.fetch('rotation_degrees', 0) * Math::PI / 180.0
                    cosine = Math.cos(radians); sine = Math.sin(radians)
                    [params['origin_mm'], [cosine, sine, 0], [-sine, cosine, 0]]
                  else
                    frame_from_transform(entity.transformation)
                  end
                  [box(*frame,
                       [0, params['width_mm'], 0, params['depth_mm'], 0, params['height_mm']])]
                when 'kitchen.run'
                  params = KitchenData.read(entity)
                  if params['layout_type'] == 'l_shaped'
                    CornerKitchen.occupied_boxes(model, params)
                  else
                    frame = frame_from_wall(Architecture.wall_entity!(model,
                      { 'homecad_id' => params['wall_id'] })[1], side: params['side'])
                    Kitchen.occupied_rectangles(params).map do |part|
                      [part['key'], box(*frame, [part['offset_mm'], part['offset_mm'] + part['width_mm'],
                        part['depth_offset_mm'], part['depth_offset_mm'] + part['depth_mm'],
                        part['bottom_mm'], part['bottom_mm'] + part['height_mm']])]
                    end
                  end
                else next
                end
        { 'homecad_id' => id, 'type' => type, 'boxes' => boxes }
      end
    end

    def self.check(model, params, exclude_run_id: nil)
      wall_params = Architecture.wall_entity!(model, { 'homecad_id' => params['wall_id'] })[1]
      frame = frame_from_wall(wall_params, side: params['side'])
      own_parts = Kitchen.occupied_rectangles(params)
      others = obstacles(model, exclude_run_id: exclude_run_id)
      own_candidates = own_parts.filter_map do |part|
        next if %w[countertop plinth].include?(part['key'])

        part_box = box(*frame, [part['offset_mm'], part['offset_mm'] + part['width_mm'],
          part['depth_offset_mm'], part['depth_offset_mm'] + part['depth_mm'],
          part['bottom_mm'], part['bottom_mm'] + part['height_mm']])
        [{ 'homecad_id' => nil, 'type' => "kitchen.#{part['type']}",
           'module_key' => part['key'] }, part_box]
      end
      other_candidates = others.flat_map do |obstacle|
        obstacle['boxes'].map do |entry|
          key, other_box = entry.is_a?(Array) ? entry : [nil, entry]
          [obstacle.merge('module_key' => key), other_box]
        end
      end
      zones = []
      findings = []
      truncated = false
      cursor = params['run_start_mm']
      params['modules'].each do |item|
        clearance = item['service_clearance_mm']
        body = [cursor, cursor + item['width_mm'], params['clearance_mm'],
                params['clearance_mm'] + item['depth_mm'], item['bottom_mm'],
                item['bottom_mm'] + item['height_mm']]
        cursor += item['width_mm']
        next unless clearance

        zones << { 'module_key' => item['key'], 'clearance_mm' => clearance,
          'bounds_attachment_mm' => { 'u' => [body[0] - clearance.fetch('u_start_mm', 0), body[1] + clearance.fetch('u_end_mm', 0)],
            'outward' => [body[2] - clearance.fetch('back_mm', 0), body[3] + clearance.fetch('front_mm', 0)],
            'z' => [body[4] - clearance.fetch('bottom_mm', 0), body[5] + clearance.fetch('top_mm', 0)] } }
        slabs(body, clearance).each do |direction, limits|
          zone = box(*frame, limits)
          (own_candidates + other_candidates).each do |obstacle, other_box|
            next if obstacle['homecad_id'].nil? && obstacle['module_key'] == item['key']
            next unless overlap?(zone, other_box)

            finding = { 'code' => 'service_clearance_blocked', 'module_key' => item['key'],
              'direction' => direction, 'object_id' => obstacle['homecad_id'],
              'object_type' => obstacle['type'], 'obstacle_key' => obstacle['module_key'] }
            next if findings.include?(finding)
            if findings.length >= MAX_FINDINGS
              truncated = true
              break
            end
            findings << finding
          end
          break if truncated
        end
        break if truncated
      end
      [zones, findings, truncated]
    end
  end
end
