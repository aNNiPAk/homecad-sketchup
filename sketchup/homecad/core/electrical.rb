module HomeCAD
  module Electrical
    KINDS = %w[outlet switch junction_box connection_point].freeze
    KEYS = %w[name placement dimensions_mm quantity sku description].freeze
    TOLERANCE_MM = 0.01

    def self.dispatch(model, method, params)
      case method
      when 'create_outlet' then create(model, params, 'outlet')
      when 'create_switch' then create(model, params, 'switch')
      when 'create_electrical_point' then create(model, params)
      when 'update_electrical_point' then update(model, params)
      when 'delete_electrical_point' then delete(model, params)
      when 'validate_electrical' then validate_scene(model, params)
      when 'assign_to_circuit' then assign(model, params)
      when 'create_circuit' then Circuits.create(model, params)
      when 'get_circuit' then Circuits.get(model, params)
      when 'list_circuits' then Circuits.list(model, params)
      when 'update_circuit' then Circuits.update(model, params)
      when 'delete_circuit' then Circuits.delete(model, params)
      else raise Runtime::BridgeError.new(-32601, 'unsupported_operation', 'unknown electrical method')
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "#{method} failed: #{error.message}")
    end

    def self.points(model)
      model.entities.to_a.select { |entity| KINDS.map { |kind| "electrical.#{kind}" }.include?(Metadata.read(entity)['type']) }
    end

    def self.vector(value, label)
      Geometry.point_mm(value, label) # shared finite, 3-coordinate validation
      length = Math.sqrt(value.sum { |part| part * part })
      Primitives.invalid!("#{label} must have a finite nonzero length") unless length.finite? && length >= 1e-9
      return value.map(&:to_f) if (length - 1.0).abs <= 1e-12
      value.map { |part| part.to_f / length }
    end

    def self.validate(model, input, defaults = {}, check_support: true)
      Primitives.check_keys!(input, KEYS)
      values = { 'name' => 'Electrical point', 'quantity' => 1, 'sku' => nil,
        'description' => nil, 'circuit_id' => nil }.merge(defaults).merge(input)
      Circuits.validate(values.slice('name', 'description'))
      values['sku'] = Furniture.validate_identifier(values['sku'], 'sku')
      Primitives.invalid!('quantity must be 1..16') unless values['quantity'].is_a?(Integer) && (1..16).cover?(values['quantity'])
      size = values['dimensions_mm']
      Primitives.invalid!('dimensions_mm must be an object') unless size.is_a?(Hash)
      Primitives.check_keys!(size, %w[width_mm height_mm depth_mm])
      values['dimensions_mm'] = %w[width_mm height_mm depth_mm].to_h { |key| [key, Geometry.positive_length(size[key], key)] }
      placement = values['placement']
      Primitives.invalid!('placement must be an object') unless placement.is_a?(Hash)
      placement = placement.dup
      case placement['mode']
      when 'wall'
        Primitives.check_keys!(placement, %w[mode wall_id offset_mm height_mm side clearance_mm])
        Architecture.wall_entity!(model, { 'homecad_id' => placement['wall_id'] })
        %w[offset_mm height_mm].each { |key| placement[key] = Geometry.finite_number(placement[key], key) }
        placement['clearance_mm'] = Geometry.finite_number(placement.fetch('clearance_mm', 0), 'clearance_mm')
        Architecture.constraint!('clearance_mm must be nonnegative') if placement['clearance_mm'].negative?
        Primitives.invalid!('side must be positive_v or negative_v') unless WallAttachment::SIDES.include?(placement['side'])
      when 'world'
        Primitives.check_keys!(placement, %w[mode origin_mm normal up])
        Geometry.point_mm(placement['origin_mm'], 'origin_mm')
        placement['origin_mm'] = placement['origin_mm'].map(&:to_f)
        normal = vector(placement['normal'], 'normal'); up = vector(placement['up'], 'up')
        projection = SceneVolumes.dot(up, normal)
        corrected = projection.abs <= 1e-12 ? up : up.zip(normal).map { |x, y| x - projection * y }
        placement['normal'] = normal; placement['up'] = vector(corrected, 'up must not be parallel to normal')
      else Primitives.invalid!('placement.mode must be wall or world')
      end
      values['placement'] = placement
      transform(model, values) # fit validation before operation
      if check_support && placement['mode'] == 'wall' && !supported?(model, values)
        Architecture.constraint!('electrical point rear area must be supported by host Wall material')
      end
      values
    end

    def self.transform(model, params)
      p = params['placement']; d = params['dimensions_mm']
      if p['mode'] == 'wall'
        wall = Architecture.wall_entity!(model, { 'homecad_id' => p['wall_id'] })[1]
        frame, normalized = Architecture.validate_wall_params!(wall)
        projection = { 'offset_mm' => p['offset_mm'] - d['width_mm']/2,
          'bottom_mm' => p['height_mm'] - d['height_mm']/2, 'side' => p['side'],
          'clearance_mm' => p['clearance_mm'], 'span_u_mm' => d['width_mm'], 'span_z_mm' => d['height_mm'] }
        WallAttachment.wall_transform(frame, normalized['thickness_mm'], projection, wall_height_mm: normalized['height_mm'])
      else
        x = SceneVolumes.cross(p['normal'], p['up'])
        d = params['dimensions_mm']
        origin = p['origin_mm'].each_with_index.map { |value, i| value - x[i]*d['width_mm']/2 - p['up'][i]*d['height_mm']/2 }
        Geom::Transformation.axes(Geometry.point_mm(origin, 'point.origin'),
          Geom::Vector3d.new(*x), Geom::Vector3d.new(*p['normal']), Geom::Vector3d.new(*p['up']))
      end
    end

    def self.supported?(model, params)
      p = params['placement']; return true unless p['mode'] == 'wall'
      _wall, wall = Architecture.wall_entity!(model, { 'homecad_id' => p['wall_id'] })
      length = WallFrame.build(wall['start_mm'], wall['end_mm']).length_mm
      d = params['dimensions_mm']; u0 = p['offset_mm'] - d['width_mm']/2; u1 = u0 + d['width_mm']
      z0 = p['height_mm'] - d['height_mm']/2; z1 = z0 + d['height_mm']
      return false if u0 < -TOLERANCE_MM || z0 < -TOLERANCE_MM || u1 > length + TOLERANCE_MM || z1 > wall['height_mm'] + TOLERANCE_MM
      cuts = Architecture.hosted_for(model, p['wall_id']).map { |host| ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type']) }
      cells = Architecture.wall_occupied_cells(length, wall['thickness_mm'], wall['height_mm'], cuts)
      half = wall['thickness_mm']/2; positive = p['side'] == 'positive_v'
      area = cells.sum do |a, b, c, e, f, g|
        next 0.0 unless ((positive ? e : c) - (positive ? half : -half)).abs <= TOLERANCE_MM
        [[b, u1].min - [a, u0].max, 0].max * [[g, z1].min - [f, z0].max, 0].max
      end
      # Comparison uses a length tolerance around the rectangle perimeter.
      (d['width_mm']*d['height_mm'] - area).abs <= TOLERANCE_MM * (d['width_mm'] + d['height_mm'])
    end

    def self.obb(entity)
      d = ElectricalData.read(entity)['dimensions_mm']; matrix = entity.transformation.to_a
      axes = [matrix[0, 3], matrix[4, 3], matrix[8, 3]]
      half = [d['width_mm']/2, d['depth_mm']/2, d['height_mm']/2]
      origin = matrix[12, 3].map { |value| Units.internal_to_mm(value) }
      center = origin.each_with_index.map { |value, i| value + axes.each_with_index.sum { |axis, j| axis[i]*half[j] } }
      { center: center, axes: axes, half: half }
    end

    def self.build(group, params)
      group.entities.clear!
      d = params['dimensions_mm']; w = Units.mm_to_internal(d['width_mm']); depth = Units.mm_to_internal(d['depth_mm'])
      face = group.entities.add_face([[0, 0, 0], [w, 0, 0], [w, depth, 0], [0, depth, 0]].map { |point| Geom::Point3d.new(*point) })
      Primitives.geometry_created!(face, 'SketchUp could not build electrical point')
      Furniture.extrude_to_positive_z!(face, Units.mm_to_internal(d['height_mm']), 'electrical point')
    end

    def self.resolve(model, selector, mutable: false)
      entry = Targeting.resolve_one(model, selector); entity = entry.entity
      Architecture.constraint!('target must be a root HomeCAD electrical point') unless entry.parent.nil? && entity.is_a?(Sketchup::Group) && points(model).include?(entity)
      Architecture.require_mutable!(entity) if mutable
      entity
    end

    def self.findings(model, selected = points(model))
      obstacles = SceneVolumes.obstacles(model)
      all_points = points(model)
      records = ElectricalData.circuits(model)
      selected.flat_map do |entity|
        id = Metadata.read(entity)['homecad_id']; params = ElectricalData.read(entity); result = []
        result << { 'category' => 'missing_support', 'severity' => 'warning', 'point_id' => id,
          'obstacle_id' => params.dig('placement', 'wall_id') } unless supported?(model, params)
        circuit = params['circuit_id']
        if circuit && records.none? { |item| item['homecad_id'] == circuit }
          result << { 'category' => 'missing_circuit', 'severity' => 'warning', 'point_id' => id, 'circuit_id' => circuit }
        end
        own = obb(entity)
        obstacles.each do |item|
          hit = item['boxes'].any? { |box| SceneVolumes.overlap?(own, SceneVolumes.upright(box.is_a?(Array) ? box.last : box)) }
          result << { 'category' => 'collision', 'severity' => 'warning', 'point_id' => id,
            'obstacle_id' => item['homecad_id'], 'obstacle_type' => item['type'] } if hit
        end
        all_points.each do |other|
          next if other.equal?(entity)
          result << { 'category' => 'collision', 'severity' => 'warning', 'point_id' => id,
            'obstacle_id' => Metadata.read(other)['homecad_id'], 'obstacle_type' => Metadata.read(other)['type'] } if SceneVolumes.overlap?(own, obb(other))
        end
        result
      end
    end

    def self.result(model, operation, entity, created: false, extra: [])
      MutationResult.success(operation: operation, revision: Metadata.read(entity)['revision'],
        created: created ? [Furniture.serialize_entity(entity)] : [],
        updated: (created ? [] : [Furniture.serialize_entity(entity)]) + extra,
        warnings: findings(model, [entity]).first(100).map { |finding| "#{finding['category']}: point #{finding['point_id']} obstacle #{finding['obstacle_id']}" })
    end

    def self.create(model, request, kind = nil)
      request = request.dup
      kind ||= request.delete('kind')
      Primitives.invalid!('unsupported electrical kind') unless KINDS.include?(kind)
      params = validate(model, request)
      Operation.run('Create electrical point', model: model) do
        group = model.entities.add_group; group.name = params['name']
        Metadata.create!(group, type: "electrical.#{kind}")
        ElectricalData.write(group, params); group.transformation = transform(model, params); build(group, params)
        result(model, "create_#{kind == 'outlet' || kind == 'switch' ? kind : 'electrical_point'}", group, created: true)
      end
    end

    def self.update(model, request)
      Primitives.check_keys!(request, %w[target changes])
      entity = resolve(model, request['target'], mutable: true); current = ElectricalData.read(entity)
      Primitives.invalid!('changes must be a nonempty object') unless request['changes'].is_a?(Hash) && !request['changes'].empty?
      proposed = validate(model, request['changes'], current)
      return result(model, 'update_electrical_point', entity) if proposed == current
      Operation.run('Update electrical point', model: model) do
        ElectricalData.write(entity, proposed); entity.name = proposed['name']; entity.transformation = transform(model, proposed)
        build(entity, proposed) if current['dimensions_mm'] != proposed['dimensions_mm']
        Metadata.increment_revision!(entity); result(model, 'update_electrical_point', entity)
      end
    end

    def self.assign(model, request)
      Primitives.check_keys!(request, %w[target circuit_id])
      entity = resolve(model, request['target'], mutable: true); current = ElectricalData.read(entity)
      Primitives.invalid!('circuit_id is required (null detaches)') unless request.key?('circuit_id')
      id = request['circuit_id']; Circuits.resolve(model, { 'homecad_id' => id }) unless id.nil?
      return result(model, 'assign_to_circuit', entity) if current['circuit_id'] == id
      Operation.run('Assign point to circuit', model: model) do
        ElectricalData.write(entity, current.merge('circuit_id' => id)); Metadata.increment_revision!(entity)
        extra = Circuits.bump(model, [current['circuit_id'], id]); result(model, 'assign_to_circuit', entity, extra: extra)
      end
    end

    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target]); entity = resolve(model, request['target'], mutable: true)
      tombstone = Furniture.serialize_entity(entity); params = ElectricalData.read(entity)
      Operation.run('Delete electrical point', model: model) do
        entity.erase!
        MutationResult.success(operation: 'delete_electrical_point', deleted: [tombstone],
          updated: Circuits.bump(model, [params['circuit_id']]), revision: tombstone['metadata']['revision'])
      end
    end

    def self.validate_scene(model, request)
      Primitives.check_keys!(request, %w[target limit offset]); limit, offset = Circuits.page(request)
      selected = request['target'] ? [resolve(model, request['target'])] : points(model)
      entries = findings(model, selected)
      { 'findings' => entries.slice(offset, limit) || [], 'total' => entries.length,
        'limit' => limit, 'offset' => offset, 'has_more' => offset + limit < entries.length }
    end

    def self.after_mutation(model, result)
      return result unless result.is_a?(Hash) && (result['operation'].to_s.include?('architecture') ||
        %w[create_opening create_door create_window create_niche].include?(result['operation']))
      deleted = result.fetch('deleted', []).select { |item| item['homecad_type'].to_s.start_with?('electrical.') }
      circuit_ids = deleted.map { |item| item.dig('parameters', 'circuit_id') }
      result['updated'] = result.fetch('updated', []) + Circuits.bump(model, circuit_ids)
      support = points(model).reject { |entity| supported?(model, ElectricalData.read(entity)) }
      result['warnings'] = result.fetch('warnings', []) + support.first(100).map { |entity| "missing_support: electrical point #{Metadata.read(entity)['homecad_id']}" }
      result
    end
  end
  DomainHooks.register(:electrical) { |model, result| Electrical.after_mutation(model, result) }
end
