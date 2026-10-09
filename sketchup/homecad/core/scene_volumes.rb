module HomeCAD
  # Canonical HomeCAD volumes; arbitrary SketchUp topology is outside the contract.
  module SceneVolumes
    def self.obstacles(model, exclude_id: nil)
      model.entities.to_a.filter_map do |entity|
        data = Metadata.read(entity); id = data['homecad_id']; type = data['type']
        next unless id && id != exclude_id
        boxes = case type
                when 'architecture.wall'
                  params = ArchitectureData.read_params(entity)
                  frame = ServiceZones.frame_from_wall(params)
                  cuts = Architecture.hosted_for(model, id).map do |host|
                    ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type'])
                  end
                  wall = Architecture.validate_wall_params!(params).last
                  length = WallFrame.build(params['start_mm'], params['end_mm']).length_mm
                  Architecture.wall_occupied_cells(length, wall['thickness_mm'], wall['height_mm'], cuts)
                    .map { |limits| ServiceZones.box(*frame, limits) }
                when 'architecture.column', 'furniture.cabinet'
                  params = type == 'architecture.column' ? ArchitectureData.read_params(entity) : FurnitureData.read_params(entity)
                  frame = if type == 'architecture.column'
                    radians = params.fetch('rotation_degrees', 0) * Math::PI / 180.0
                    cosine = Math.cos(radians); sine = Math.sin(radians)
                    [params['origin_mm'], [cosine, sine, 0], [-sine, cosine, 0]]
                  else
                    ServiceZones.frame_from_transform(entity.transformation)
                  end
                  [ServiceZones.box(*frame, [0, params['width_mm'], 0, params['depth_mm'], 0, params['height_mm']])]
                when 'kitchen.run'
                  params = KitchenData.read(entity)
                  if params['layout_type'] == 'l_shaped'
                    CornerKitchen.occupied_boxes(model, params)
                  else
                    frame = ServiceZones.frame_from_wall(Architecture.wall_entity!(model,
                      { 'homecad_id' => params['wall_id'] })[1], side: params['side'])
                    Kitchen.occupied_rectangles(params).map do |part|
                      [part['key'], ServiceZones.box(*frame, [part['offset_mm'], part['offset_mm'] + part['width_mm'],
                        part['depth_offset_mm'], part['depth_offset_mm'] + part['depth_mm'],
                        part['bottom_mm'], part['bottom_mm'] + part['height_mm']])]
                    end
                  end
                else next
                end
        { 'homecad_id' => id, 'type' => type, 'boxes' => boxes }
      end
    end

    def self.upright(box)
      u0, u1, v0, v1, z0, z1 = box[:limits]
      axes = [box[:x], box[:y], [0, 0, 1]]
      center = box[:origin].each_with_index.map do |origin, i|
        origin + axes[0][i] * (u0 + u1) / 2 + axes[1][i] * (v0 + v1) / 2 + axes[2][i] * (z0 + z1) / 2
      end
      { center: center, axes: axes, half: [(u1-u0)/2, (v1-v0)/2, (z1-z0)/2] }
    end

    def self.dot(a, b) = a.zip(b).sum { |x, y| x * y }
    def self.cross(a, b) = [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
    def self.bounds(box)
      extent = 3.times.map { |i| box[:axes].each_with_index.sum { |axis, j| axis[i].abs * box[:half][j] } }
      box[:center].zip(extent).map { |center, radius| [center-radius, center+radius] }
    end

    def self.overlap?(a, b, tolerance: 0.01)
      return false unless bounds(a).zip(bounds(b)).all? { |x, y| [x[1], y[1]].min - [x[0], y[0]].max > tolerance }
      delta = a[:center].zip(b[:center]).map { |x, y| y-x }
      axes = a[:axes] + b[:axes] + a[:axes].product(b[:axes]).map { |x, y| cross(x, y) }
      axes.all? do |axis|
        length = Math.sqrt(dot(axis, axis))
        next true if length < 1e-9
        unit = axis.map { |value| value / length }
        radius = [a, b].sum { |box| box[:axes].each_with_index.sum { |basis, j| dot(unit, basis).abs * box[:half][j] } }
        radius - dot(delta, unit).abs > tolerance
      end
    end
  end
end
