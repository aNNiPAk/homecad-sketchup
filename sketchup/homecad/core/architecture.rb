require 'json'

module HomeCAD
  module ArchitectureData
    PARAMS_KEY = 'architecture_params_json'.freeze
    RELATIONSHIPS_KEY = 'architecture_relationships_json'.freeze

    def self.read_params(entity)
      read_json(entity, PARAMS_KEY)
    end

    def self.read_relationships(entity)
      read_json(entity, RELATIONSHIPS_KEY)
    end

    def self.write(entity, params:, relationships: {})
      entity.set_attribute(Metadata::DICTIONARY, PARAMS_KEY,
                           JSON.generate(canonical(params)))
      entity.set_attribute(Metadata::DICTIONARY, RELATIONSHIPS_KEY,
                           JSON.generate(canonical(relationships)))
      relationships.each do |key, value|
        entity.set_attribute(Metadata::DICTIONARY, key.to_s, value) if key.to_s.end_with?('_id')
      end
      true
    end

    def self.read_json(entity, key)
      value = Metadata.read(entity)[key]
      return {} unless value.is_a?(String) && !value.empty?

      parsed = JSON.parse(value)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      raise Runtime::BridgeError.new(-32603, 'invalid_response', "stored #{key} is malformed")
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key.to_s, canonical(value[key])] }
      when Array then value.map { |item| canonical(item) }
      when String, Numeric, TrueClass, FalseClass, NilClass then value
      else
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'architecture metadata must contain JSON values')
      end
    end
  end

  class WallFrame
    Z_AXIS = [0.0, 0.0, 1.0].freeze
    attr_reader :origin_mm, :u_axis, :v_axis, :z_axis, :length_mm

    def self.build(start_mm, end_mm)
      start = Architecture.validate_point!(start_mm, 'start_mm')
      finish = Architecture.validate_point!(end_mm, 'end_mm')
      if (start[2] - finish[2]).abs > Architecture::TOLERANCE_MM[:point]
        Architecture.constraint!('wall baseline must be horizontal in plan')
      end
      dx = finish[0] - start[0]
      dy = finish[1] - start[1]
      length = Math.sqrt(dx * dx + dy * dy)
      if length <= Architecture::TOLERANCE_MM[:minimum_wall_length]
        Architecture.invalid!('wall length must exceed the minimum wall length')
      end
      new(start, [dx / length, dy / length, 0.0], [-dy / length, dx / length, 0.0], length)
    end

    def initialize(origin_mm, u_axis, v_axis, length_mm)
      @origin_mm = origin_mm.freeze
      @u_axis = u_axis.freeze
      @v_axis = v_axis.freeze
      @z_axis = Z_AXIS
      @length_mm = length_mm
    end

    def local_to_world(u_mm, v_mm, z_mm)
      [0, 1, 2].map do |axis|
        origin_mm[axis] + u_axis[axis] * u_mm + v_axis[axis] * v_mm + z_axis[axis] * z_mm
      end
    end

    def world_to_local(point_mm)
      point = Architecture.validate_point!(point_mm, 'point_mm')
      delta = 3.times.map { |index| point[index] - origin_mm[index] }
      [self.class.dot(delta, u_axis), self.class.dot(delta, v_axis), self.class.dot(delta, z_axis)]
    end

    def to_h(wall_id:, thickness_mm:, height_mm:)
      { 'wall_id' => wall_id, 'origin_mm' => origin_mm, 'u_axis' => u_axis,
        'v_axis' => v_axis, 'z_axis' => z_axis, 'length_mm' => length_mm,
        'thickness_mm' => thickness_mm, 'height_mm' => height_mm }
    end

    def self.dot(a, b) = 3.times.sum { |index| a[index] * b[index] }
    private_class_method :new
  end

  module Architecture
    TOLERANCE_MM = { point: 1.0, cut: 0.01, minimum_wall_length: 10.0,
                     minimum_dimension: 0.1 }.freeze
    MAX_HOSTED_CUTS = 16
    MAX_NICHES = 4
    TYPES = %w[architecture.wall architecture.opening architecture.door
               architecture.window architecture.niche architecture.column
               architecture.room].freeze
    HOSTED_TYPES = %w[architecture.opening architecture.door architecture.window
                      architecture.niche].freeze
    THROUGH_TYPES = %w[architecture.opening architecture.door architecture.window].freeze
    SIDES = %w[center positive_v negative_v].freeze
    FORBIDDEN_CHANGES = %w[homecad_id type schema_version].freeze

    def self.dispatch(model, method, params)
      case method
      when 'get_wall_frame' then get_wall_frame(model, params)
      when 'create_wall' then create_wall(model, params)
      when 'create_opening' then create_hosted(model, 'architecture.opening', params)
      when 'create_door' then create_hosted(model, 'architecture.door', params)
      when 'create_window' then create_hosted(model, 'architecture.window', params)
      when 'create_niche' then create_hosted(model, 'architecture.niche', params)
      when 'create_column' then create_column(model, params)
      when 'update_architecture_object' then update_object(model, params)
      when 'delete_architecture_object' then delete_object(model, params)
      when 'create_room' then create_room(model, params)
      when 'detect_rooms' then detect_rooms(model, params)
      else
        raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "unknown architecture method: #{method}")
      end
    end

    def self.validate_point!(value, label)
      unless value.is_a?(Array) && value.length == 3 && value.all? { |number| finite?(number) }
        invalid!("#{label} must be three finite millimeter coordinates")
      end
      value.map(&:to_f)
    end

    def self.finite?(value)
      value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
    end

    def self.positive!(value, label)
      invalid!("#{label} must be finite and positive") unless finite?(value) && value.to_f > TOLERANCE_MM[:minimum_dimension]
      value.to_f
    end

    def self.validate_wall_params!(params)
      start = validate_point!(params['start_mm'], 'start_mm')
      finish = validate_point!(params['end_mm'], 'end_mm')
      frame = WallFrame.build(start, finish)
      thickness = positive!(params['thickness_mm'], 'thickness_mm')
      height = positive!(params['height_mm'], 'height_mm')
      [frame, params.merge('start_mm' => start, 'end_mm' => finish,
                           'thickness_mm' => thickness, 'height_mm' => height)]
    end

    def self.wall_entity!(model, selector)
      entry = Targeting.resolve_one(model, selector)
      entity = entry.entity
      metadata = Metadata.read(entity)
      constraint!('host wall must be a root-level HomeCAD Wall') unless entry.parent.nil? &&
        metadata['type'] == 'architecture.wall' && entity.is_a?(Sketchup::Group)
      [entity, ArchitectureData.read_params(entity), metadata]
    end

    def self.hosted_for(model, wall_id)
      model.entities.to_a.select do |entity|
        data = Metadata.read(entity)
        data['type'].to_s.start_with?('architecture.') && data['wall_id'] == wall_id
      end
    end

    def self.rooms_for(model, wall_id)
      model.entities.to_a.select do |entity|
        data = Metadata.read(entity)
        data['type'] == 'architecture.room' && ArchitectureData.read_params(entity)['wall_ids'].to_a.include?(wall_id)
      end
    end

    def self.validate_cut!(type, params, wall_params)
      offset = finite_value!(params['offset_mm'], 'offset_mm')
      bottom = type == 'architecture.door' ? 0.0 : finite_value!(params.fetch('bottom_mm', 0), 'bottom_mm')
      width = positive!(params['width_mm'], 'width_mm')
      height = positive!(params['height_mm'], 'height_mm')
      frame, wall = validate_wall_params!(wall_params)
      if offset < -TOLERANCE_MM[:cut] || bottom < -TOLERANCE_MM[:cut] ||
         offset + width > frame.length_mm + TOLERANCE_MM[:cut] || bottom + height > wall['height_mm'] + TOLERANCE_MM[:cut]
        constraint!('hosted cut must fit within the wall bounds')
      end
      side = params.fetch('side', 'center')
      invalid!('side must be center, positive_v, or negative_v') unless SIDES.include?(side)
      depth_offset = finite_value!(params.fetch('depth_offset_mm', 0), 'depth_offset_mm')
      constraint!('depth_offset_mm must remain within the wall thickness') if depth_offset.abs > wall['thickness_mm'] / 2.0 + TOLERANCE_MM[:cut]
      if type == 'architecture.niche'
        depth = positive!(params['depth_mm'], 'depth_mm')
        constraint!('niche side must be positive_v or negative_v') if side == 'center'
        constraint!('niche depth must be less than wall thickness') if depth >= wall['thickness_mm'] - TOLERANCE_MM[:cut]
        depth_offset = side == 'positive_v' ? wall['thickness_mm'] / 2.0 - depth : -wall['thickness_mm'] / 2.0
      else
        depth = wall['thickness_mm']
      end
      normalized = params.merge('offset_mm' => offset, 'bottom_mm' => bottom,
        'width_mm' => width, 'height_mm' => height, 'depth_offset_mm' => depth_offset,
        'side' => side)
      normalized['depth_mm'] = depth if type == 'architecture.niche'
      [frame, wall, normalized]
    end

    def self.validate_cuts!(cuts)
      constraint!('wall supports at most 16 hosted cuts') if cuts.length > MAX_HOSTED_CUTS
      constraint!('wall supports at most 4 niches') if cuts.count { |cut| cut['type'] == 'architecture.niche' } > MAX_NICHES
      cuts.combination(2) do |left, right|
        overlap_u = [left['offset_mm'], right['offset_mm']].max <
                    [left['offset_mm'] + left['width_mm'], right['offset_mm'] + right['width_mm']].min - TOLERANCE_MM[:cut]
        overlap_z = [left['bottom_mm'], right['bottom_mm']].max <
                    [left['bottom_mm'] + left['height_mm'], right['bottom_mm'] + right['height_mm']].min - TOLERANCE_MM[:cut]
        # Conservative M3 policy rejects coincident U/Z cut regions, including niche/through overlap.
        constraint!('hosted wall cuts may not overlap') if overlap_u && overlap_z
      end
      true
    end

    # Returns the boundary quads of a rectilinear wall solid. No SketchUp boolean API is used.
    def self.wall_boundary_quads(length, thickness, height, cuts)
      us = ([0.0, length] + cuts.flat_map { |cut| [cut['offset_mm'], cut['offset_mm'] + cut['width_mm']] }).uniq.sort
      zs = ([0.0, height] + cuts.flat_map { |cut| [cut['bottom_mm'], cut['bottom_mm'] + cut['height_mm']] }).uniq.sort
      half = thickness / 2.0
      vs = [-half, half] + cuts.select { |cut| cut['type'] == 'architecture.niche' }.flat_map do |cut|
        cut['side'] == 'positive_v' ? [half - cut['depth_mm']] : [-half + cut['depth_mm']]
      end
      vs = vs.uniq.sort
      occupied = lambda do |u, v, z|
        cuts.none? do |cut|
          in_uz = u > cut['offset_mm'] - TOLERANCE_MM[:cut] &&
                  u < cut['offset_mm'] + cut['width_mm'] + TOLERANCE_MM[:cut] &&
                  z > cut['bottom_mm'] - TOLERANCE_MM[:cut] &&
                  z < cut['bottom_mm'] + cut['height_mm'] + TOLERANCE_MM[:cut]
          next false unless in_uz
          next true if THROUGH_TYPES.include?(cut['type'])

          v0 = cut['side'] == 'positive_v' ? half - cut['depth_mm'] : -half
          v1 = cut['side'] == 'positive_v' ? half : -half + cut['depth_mm']
          v > v0 - TOLERANCE_MM[:cut] && v < v1 + TOLERANCE_MM[:cut]
        end
      end
      faces = []
      nu = us.length - 1
      nv = vs.length - 1
      nz = zs.length - 1
      nu.times do |i|
        nv.times do |j|
          nz.times do |k|
            center = [(us[i] + us[i + 1]) / 2.0, (vs[j] + vs[j + 1]) / 2.0, (zs[k] + zs[k + 1]) / 2.0]
            next unless occupied.call(*center)
            # Emit a quad only where the neighboring cell is empty/outside. This avoids duplicate internal faces.
            faces << [[us[i], vs[j], zs[k + 1]], [us[i], vs[j + 1], zs[k + 1]], [us[i], vs[j + 1], zs[k]], [us[i], vs[j], zs[k]]] if i.zero? || !occupied.call((us[i - 1] + us[i]) / 2.0, center[1], center[2])
            faces << [[us[i + 1], vs[j], zs[k]], [us[i + 1], vs[j + 1], zs[k]], [us[i + 1], vs[j + 1], zs[k + 1]], [us[i + 1], vs[j], zs[k + 1]]] if i == nu - 1 || !occupied.call((us[i + 1] + us[i + 2]) / 2.0, center[1], center[2])
            faces << [[us[i + 1], vs[j], zs[k]], [us[i + 1], vs[j], zs[k + 1]], [us[i], vs[j], zs[k + 1]], [us[i], vs[j], zs[k]]] if j.zero? || !occupied.call(center[0], (vs[j - 1] + vs[j]) / 2.0, center[2])
            faces << [[us[i], vs[j + 1], zs[k + 1]], [us[i + 1], vs[j + 1], zs[k + 1]], [us[i + 1], vs[j + 1], zs[k]], [us[i], vs[j + 1], zs[k]]] if j == nv - 1 || !occupied.call(center[0], (vs[j + 1] + vs[j + 2]) / 2.0, center[2])
            faces << [[us[i], vs[j + 1], zs[k]], [us[i + 1], vs[j + 1], zs[k]], [us[i + 1], vs[j], zs[k]], [us[i], vs[j], zs[k]]] if k.zero? || !occupied.call(center[0], center[1], (zs[k - 1] + zs[k]) / 2.0)
            faces << [[us[i], vs[j], zs[k + 1]], [us[i + 1], vs[j], zs[k + 1]], [us[i + 1], vs[j + 1], zs[k + 1]], [us[i], vs[j + 1], zs[k + 1]]] if k == nz - 1 || !occupied.call(center[0], center[1], (zs[k + 1] + zs[k + 2]) / 2.0)
          end
        end
      end
      faces
    end

    def self.regenerate_wall!(group, wall_params, cuts)
      frame, wall = validate_wall_params!(wall_params)
      validate_cuts!(cuts)
      group.entities.clear!
      transform = Geom::Transformation.axes(
        Geometry.point_mm(frame.origin_mm, 'wall.start_mm'),
        Geom::Vector3d.new(*frame.u_axis), Geom::Vector3d.new(*frame.v_axis), Geom::Vector3d.new(*frame.z_axis))
      group.transformation = transform
      wall_boundary_quads(frame.length_mm, wall['thickness_mm'], wall['height_mm'], cuts).each do |quad|
        points = quad.map { |u, v, z| Geom::Point3d.new(Units.mm_to_internal(u), Units.mm_to_internal(v), Units.mm_to_internal(z)) }
        Primitives.geometry_created!(group.entities.add_face(points), 'SketchUp could not regenerate wall geometry')
      end
      [frame, wall]
    end

    def self.get_wall_frame(model, params)
      Primitives.check_keys!(params, %w[wall target])
      invalid!('provide either wall or target, not both') if params.key?('wall') && params.key?('target')
      selector = params['wall'] || params['target']
      wall, wall_params, metadata = wall_entity!(model, selector)
      frame, normalized = validate_wall_params!(wall_params)
      frame.to_h(wall_id: metadata['homecad_id'], thickness_mm: normalized['thickness_mm'],
                 height_mm: normalized['height_mm'])
    end

    def self.create_wall(model, params)
      Primitives.check_keys!(params, %w[start_mm end_mm thickness_mm height_mm name])
      name!(params['name'])
      frame, normalized = validate_wall_params!(params)
      Operation.run('Create wall', model: model) do
        group = model.entities.add_group
        Primitives.geometry_created!(group, 'SketchUp could not create wall Group')
        group.name = params['name'] if params['name']
        Metadata.create!(group, type: 'architecture.wall')
        ArchitectureData.write(group, params: normalized)
        regenerate_wall!(group, normalized, [])
        mutation_result('create_wall', created: [group], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('create_wall', error)
    end

    def self.create_hosted(model, type, params)
      allowed = %w[wall offset_mm bottom_mm width_mm height_mm depth_mm depth_offset_mm side name]
      Primitives.check_keys!(params, allowed)
      name!(params['name'])
      wall, wall_params, wall_metadata = wall_entity!(model, params['wall'])
      require_mutable!(wall)
      _frame, normalized_wall, normalized = validate_cut!(type, params, wall_params)
      normalized.delete('wall')
      normalized['type'] = type
      normalized['name'] = params['name'] if params['name']
      candidates = hosted_for(model, wall_metadata['homecad_id']).map do |entity|
        ArchitectureData.read_params(entity).merge('type' => Metadata.read(entity)['type'])
      end
      validate_cuts!(candidates + [normalized])
      Operation.run("Create #{type.split('.').last}", model: model) do
        group = model.entities.add_group
        Primitives.geometry_created!(group, 'SketchUp could not create hosted object Group')
        group.name = params['name'] if params['name']
        Metadata.create!(group, type: type)
        ArchitectureData.write(group, params: normalized, relationships: { 'wall_id' => wall_metadata['homecad_id'] })
        create_window_visual!(group, normalized_wall, normalized) if type == 'architecture.window'
        cuts = candidates + [normalized]
        regenerate_wall!(wall, normalized_wall, cuts)
        Metadata.increment_revision!(wall)
        mutation_result("create_#{type.split('.').last}", created: [group], updated: [wall], revision: Metadata.read(group)['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!("create_#{type.split('.').last}", error)
    end

    def self.create_column(model, params)
      Primitives.check_keys!(params, %w[origin_mm width_mm depth_mm height_mm rotation_degrees name])
      name!(params['name'])
      origin = validate_point!(params['origin_mm'], 'origin_mm')
      width = positive!(params['width_mm'], 'width_mm')
      depth = positive!(params['depth_mm'], 'depth_mm')
      height = positive!(params['height_mm'], 'height_mm')
      angle = finite_value!(params.fetch('rotation_degrees', 0), 'rotation_degrees')
      normalized = params.merge('origin_mm' => origin, 'width_mm' => width,
        'depth_mm' => depth, 'height_mm' => height, 'rotation_degrees' => angle)
      Operation.run('Create column', model: model) do
        group = model.entities.add_group
        group.name = params['name'] if params['name']
        Metadata.create!(group, type: 'architecture.column')
        ArchitectureData.write(group, params: normalized)
        regenerate_column!(group, normalized)
        mutation_result('create_column', created: [group], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('create_column', error)
    end

    def self.update_object(model, params)
      Primitives.check_keys!(params, %w[target changes])
      entry = Targeting.resolve_one(model, params['target'])
      group = entry.entity
      require_mutable!(group)
      constraint!('architecture target must be a root-level managed Group') unless entry.parent.nil? && group.is_a?(Sketchup::Group)
      data = Metadata.read(group)
      type = data['type']
      constraint!('target is not a supported architecture object') unless TYPES.include?(type)
      changes = params['changes']
      invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      invalid!('immutable identity fields cannot be changed') unless (changes.keys & FORBIDDEN_CHANGES).empty?
      current = ArchitectureData.read_params(group)
      allowed_changes = case type
                        when 'architecture.wall' then %w[start_mm end_mm thickness_mm height_mm name]
                        when *HOSTED_TYPES then %w[offset_mm bottom_mm width_mm height_mm depth_mm depth_offset_mm side name]
                        when 'architecture.column' then %w[origin_mm width_mm depth_mm height_mm rotation_degrees name]
                        when 'architecture.room' then %w[name wall_ids]
                        else []
                        end
      invalid!("unsupported changes: #{(changes.keys - allowed_changes).join(', ')}") unless (changes.keys - allowed_changes).empty?
      proposed = current.merge(changes)
      wall = nil
      rooms_to_update = []
      if type == 'architecture.wall'
        frame, proposed = validate_wall_params!(proposed)
        hosts = hosted_for(model, data['homecad_id'])
        hosts.each { |host| require_mutable!(host) }
        cuts = hosts.map { |host| ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type']) }
        validate_cuts!(cuts)
        cuts.each do |cut|
          constraint!('wall update would invalidate a hosted object') if cut['offset_mm'] + cut['width_mm'] > frame.length_mm + TOLERANCE_MM[:cut] || cut['bottom_mm'] + cut['height_mm'] > proposed['height_mm'] + TOLERANCE_MM[:cut]
        end
        rooms_for(model, data['homecad_id']).each do |room|
          require_mutable!(room)
          room_params = ArchitectureData.read_params(room)
          points, sides = room_boundary!(model, room_params['wall_ids'], overrides: { data['homecad_id'] => proposed })
          revised_room = room_params.merge('boundary_mm' => points, 'room_sides' => sides,
            'approx_area_mm2' => polygon_area(points).abs)
          rooms_to_update << [room, revised_room]
        end
      elsif HOSTED_TYPES.include?(type)
        wall, wall_params, wall_meta = wall_entity!(model, { 'homecad_id' => data['wall_id'] })
        require_mutable!(wall)
        _frame, _wall, proposed = validate_cut!(type, proposed, wall_params)
        other = hosted_for(model, wall_meta['homecad_id']).reject { |candidate| candidate.equal?(group) }.map do |host|
          ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type'])
        end
        validate_cuts!(other + [proposed.merge('type' => type)])
      elsif type == 'architecture.column'
        proposed['origin_mm'] = validate_point!(proposed['origin_mm'], 'origin_mm')
        %w[width_mm depth_mm height_mm].each { |key| proposed[key] = positive!(proposed[key], key) }
        proposed['rotation_degrees'] = finite_value!(proposed.fetch('rotation_degrees', 0), 'rotation_degrees')
      elsif type == 'architecture.room'
        _points, sides = room_boundary!(model, proposed['wall_ids'])
        proposed['room_sides'] = sides
      end
      Operation.run('Update architecture object', model: model) do
        updated = [group]
        case type
        when 'architecture.wall'
          ArchitectureData.write(group, params: proposed)
          cuts = hosted_for(model, data['homecad_id']).map { |host| ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type']) }
          regenerate_wall!(group, proposed, cuts)
          hosts = hosted_for(model, data['homecad_id'])
          hosts.each do |host|
            next unless Metadata.read(host)['type'] == 'architecture.window'
            host.entities.clear!
            create_window_visual!(host, proposed, ArchitectureData.read_params(host))
          end
          updated.concat(hosts)
          rooms_to_update.each do |room, room_params|
            ArchitectureData.write(room, params: room_params, relationships: ArchitectureData.read_relationships(room))
            regenerate_room!(room, room_params)
            updated << room
          end
        when *HOSTED_TYPES
          ArchitectureData.write(group, params: proposed, relationships: { 'wall_id' => data['wall_id'] })
          if type == 'architecture.window'
            group.entities.clear!
            create_window_visual!(group, ArchitectureData.read_params(wall), proposed)
          end
          cuts = hosted_for(model, data['wall_id']).map { |host| ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type']) }
          regenerate_wall!(wall, ArchitectureData.read_params(wall), cuts)
          updated << wall
        when 'architecture.column' then regenerate_column!(group, proposed)
        when 'architecture.room' then regenerate_room!(group, proposed)
        end
        ArchitectureData.write(group, params: proposed, relationships: ArchitectureData.read_relationships(group)) unless type == 'architecture.wall'
        group.name = proposed['name'] if proposed['name'].is_a?(String)
        updated.each { |entity| Metadata.increment_revision!(entity) }
        mutation_result('update_architecture_object', updated: updated.uniq, revision: Metadata.read(group)['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('update_architecture_object', error)
    end

    def self.delete_object(model, params)
      Primitives.check_keys!(params, %w[target cascade])
      entry = Targeting.resolve_one(model, params['target'])
      group = entry.entity
      require_mutable!(group)
      constraint!('architecture target must be a root-level managed Group') unless entry.parent.nil? && group.is_a?(Sketchup::Group)
      metadata = Metadata.read(group)
      type = metadata['type']
      constraint!('target is not a supported architecture object') unless TYPES.include?(type)
      cascade = params.fetch('cascade', false)
      invalid!('cascade must be boolean') unless [true, false].include?(cascade)
      wall = nil
      dependents = []
      if type == 'architecture.wall'
        dependents = hosted_for(model, metadata['homecad_id']) + rooms_for(model, metadata['homecad_id'])
        dependents.each { |entity| require_mutable!(entity) }
        constraint!('wall has hosted objects; set cascade=true to delete them') if dependents.any? && !cascade
      elsif HOSTED_TYPES.include?(type)
        wall, = wall_entity!(model, { 'homecad_id' => metadata['wall_id'] })
        require_mutable!(wall)
      end
      tombstones = (dependents + [group]).map { |entity| serialize_entity(entity) }
      Operation.run('Delete architecture object', model: model) do
        model.entities.erase_entities(*(dependents + [group]))
        if wall
          cuts = hosted_for(model, metadata['wall_id']).map { |host| ArchitectureData.read_params(host).merge('type' => Metadata.read(host)['type']) }
          regenerate_wall!(wall, ArchitectureData.read_params(wall), cuts)
          Metadata.increment_revision!(wall)
        end
        MutationResult.success(operation: 'delete_architecture_object', deleted: tombstones,
          updated: wall ? [serialize_entity(wall)] : [], revision: wall ? Metadata.read(wall)['revision'] : metadata['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('delete_architecture_object', error)
    end

    def self.create_room(model, params)
      Primitives.check_keys!(params, %w[name wall_ids])
      name!(params['name'])
      points, sides = room_boundary!(model, params['wall_ids'])
      params_out = { 'name' => params['name'], 'wall_ids' => params['wall_ids'],
                     'room_sides' => sides, 'boundary_mm' => points,
                     'approx_area_mm2' => polygon_area(points).abs }
      Operation.run('Create room', model: model) do
        group = model.entities.add_group
        group.name = params['name'] if params['name']
        Metadata.create!(group, type: 'architecture.room')
        ArchitectureData.write(group, params: params_out, relationships: sides.to_h { |wall_id, side| ["wall_#{wall_id}", side] })
        regenerate_room!(group, params_out)
        mutation_result('create_room', created: [group], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('create_room', error)
    end

    def self.detect_rooms(model, params)
      Primitives.check_keys!(params, %w[])
      walls = model.entities.to_a.filter_map do |entity|
        data = Metadata.read(entity)
        next unless data['type'] == 'architecture.wall'
        wall_params = ArchitectureData.read_params(entity)
        [data['homecad_id'], wall_params['start_mm'], wall_params['end_mm']]
      end
      nodes = []
      edges = walls.map do |id, start, finish|
        [node_index(nodes, start), node_index(nodes, finish), id, start, finish]
      end
      warnings = []
      crossing_edges = []
      edges.each_with_index do |left, left_index|
        ((left_index + 1)...edges.length).each do |right_index|
          right = edges[right_index]
          crossing_edges.concat([left_index, right_index]) if baseline_crossing?(left[3], left[4], right[3], right[4])
        end
      end
      warnings << 'Room detection skipped crossing or T-junction wall topology.' unless crossing_edges.empty?
      components = edge_components(edges, nodes.length)
      candidates = components.filter_map do |component|
        next if (component & crossing_edges).any?
        degrees = Hash.new(0)
        component.each { |index| degrees[edges[index][0]] += 1; degrees[edges[index][1]] += 1 }
        unless degrees.values.all? { |degree| degree == 2 }
          warnings << 'Skipped a wall component with open endpoints or ambiguous degree.'
          next
        end
        next if component.length < 3
        ordered = order_cycle(component, edges)
        next unless ordered
        points = ordered.map { |edge_index, direction| direction ? edges[edge_index][3] : edges[edge_index][4] }
        area = polygon_area(points)
        next if area.abs <= TOLERANCE_MM[:minimum_wall_length]**2
        { 'wall_ids' => ordered.map { |edge_index, _| edges[edge_index][2] },
          'approx_area_mm2' => area.abs, 'orientation' => area.positive? ? 'counterclockwise' : 'clockwise' }
      end
      { 'candidates' => candidates, 'warnings' => warnings }
    end

    def self.room_boundary!(model, wall_ids, overrides: {})
      unless wall_ids.is_a?(Array) && wall_ids.length >= 3 && wall_ids.uniq.length == wall_ids.length && wall_ids.all? { |id| id.is_a?(String) }
        invalid!('wall_ids must be an ordered array of at least three distinct HomeCAD wall IDs')
      end
      walls = wall_ids.map do |id|
        entity, params, metadata = wall_entity!(model, { 'homecad_id' => id })
        [entity, overrides.fetch(id, params), metadata]
      end
      segments = walls.map { |entity, params, metadata| [entity, params, metadata, params['start_mm'], params['end_mm']] }
      directed = nil
      [true, false].each do |first_forward|
        candidate = []
        current = first_forward ? segments.first[4] : segments.first[3]
        candidate << [first_forward ? segments.first[3] : segments.first[4], first_forward]
        valid = true
        segments.drop(1).each do |segment|
          start, finish = segment[3], segment[4]
          if distance(start, current) <= TOLERANCE_MM[:point]
            candidate << [start, true]
            current = finish
          elsif distance(finish, current) <= TOLERANCE_MM[:point]
            candidate << [finish, false]
            current = start
          else
            valid = false
            break
          end
        end
        if valid && distance(current, candidate.first[0]) <= TOLERANCE_MM[:point]
          directed = candidate
          break
        end
      end
      constraint!('ordered room walls do not form one closed loop') unless directed
      points = directed.map(&:first)
      constraint!('room walls must lie at one floor elevation') if points.map(&:last).max - points.map(&:last).min > TOLERANCE_MM[:cut]
      constraint!('room boundary is not a simple nonzero-area loop') if self_intersects?(points) || polygon_area(points).abs <= TOLERANCE_MM[:minimum_wall_length]**2
      orientation = polygon_area(points).positive? ? 1 : -1
      sides = segments.each_with_index.map do |(_entity, _wall_params, metadata, _start, _finish), index|
        # Boundary traversal's direction relative to wall U selects the inward V side.
        forward = directed[index][1]
        [metadata['homecad_id'], (forward ? orientation : -orientation).positive? ? 'positive_v' : 'negative_v']
      end
      [points, sides]
    end

    def self.regenerate_column!(group, params)
      group.entities.clear!
      group.transformation = Geom::Transformation.new
        origin = Geometry.point_mm(params['origin_mm'], 'origin_mm')
      width = Units.mm_to_internal(params['width_mm'])
      depth = Units.mm_to_internal(params['depth_mm'])
      height = Units.mm_to_internal(params['height_mm'])
      pts = [[0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0]].map do |x, y, z|
        Geom::Point3d.new(origin.x + x, origin.y + y, origin.z + z)
      end
      face = group.entities.add_face(pts)
      Primitives.geometry_created!(face, 'SketchUp could not create column base')
      face.pushpull(height)
      angle = params['rotation_degrees'].to_f * Math::PI / 180.0
      if angle.abs > 1e-9
        group.transform!(Geom::Transformation.rotation(origin, Geom::Vector3d.new(0, 0, 1), angle))
      end
      group
    end

    def self.regenerate_room!(group, params)
      group.entities.clear!
      floor = params['boundary_mm'].map { |point| Geometry.point_mm(point, 'room.boundary') }
      face = Primitives.geometry_created!(group.entities.add_face(floor), 'SketchUp could not regenerate room reference face')
      face.reverse! if face.respond_to?(:normal) && face.normal.z.negative? && face.respond_to?(:reverse!)
      group
    end

    def self.require_mutable!(entity)
      unless entity.respond_to?(:valid?) && entity.valid? &&
             (!entity.respond_to?(:deleted?) || !entity.deleted?)
        raise Runtime::BridgeError.new(-32002, 'target_not_found', 'architecture target is deleted or invalid')
      end
      if entity.respond_to?(:locked?) && entity.locked?
        constraint!('locked architecture objects cannot be mutated')
      end
      entity
    end

    def self.create_window_visual!(group, wall_params, window_params)
      frame, wall = validate_wall_params!(wall_params)
      u0 = window_params['offset_mm']
      u1 = u0 + window_params['width_mm']
      z0 = window_params['bottom_mm']
      z1 = z0 + window_params['height_mm']
      half = wall['thickness_mm'] / 2.0
      v = case window_params['side']
          when 'negative_v' then -half + 1.0
          when 'positive_v' then half - 1.0
          else [[window_params['depth_offset_mm'], -half + 1.0].max, half - 1.0].min
          end
      rail = [40.0, [window_params['width_mm'], window_params['height_mm']].min / 8.0].min
      glass = [[u0 + rail, z0 + rail], [u1 - rail, z0 + rail],
               [u1 - rail, z1 - rail], [u0 + rail, z1 - rail]].map do |u, z|
        Geometry.point_mm(frame.local_to_world(u, v, z), 'window.glass')
      end
      Primitives.geometry_created!(group.entities.add_face(glass), 'SketchUp could not create window glass panel')
      [[u0, z0, u1, z0], [u1, z0, u1, z1], [u1, z1, u0, z1], [u0, z1, u0, z0]].each do |u0_edge, z0_edge, u1_edge, z1_edge|
        first = Geometry.point_mm(frame.local_to_world(u0_edge, v, z0_edge), 'window.frame')
        last = Geometry.point_mm(frame.local_to_world(u1_edge, v, z1_edge), 'window.frame')
        Primitives.geometry_created!(group.entities.add_line(first, last), 'SketchUp could not create window frame')
      end
      group
    end

    def self.mutation_result(operation, created: [], updated: [], revision:)
      MutationResult.success(operation: operation,
        created: created.map { |entity| serialize_entity(entity) },
        updated: updated.map { |entity| serialize_entity(entity) }, revision: revision)
    end

    def self.serialize_entity(entity)
      entry = Scene::Entry.new(entity: entity, parent: nil, path: [Scene.id(entity)], transform: nil)
      serialized = Serializer.serialize(entry, level: 'detailed')
      serialized['parameters'] = ArchitectureData.read_params(entity)
      serialized['relationships'] = ArchitectureData.read_relationships(entity)
      serialized
    end

    def self.name!(name)
      invalid!('name must be a string') unless name.nil? || name.is_a?(String)
    end

    def self.finite_value!(value, label)
      invalid!("#{label} must be a finite number") unless finite?(value)
      value.to_f
    end

    def self.constraint!(message)
      raise Runtime::BridgeError.new(-32008, 'constraint_violation', message)
    end

    def self.invalid!(message)
      Primitives.invalid!(message)
    end

    def self.geometry_error!(operation, error)
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "#{operation} failed: #{error.message}")
    end

    def self.distance(a, b) = Math.sqrt(3.times.sum { |index| (a[index] - b[index])**2 })
    def self.polygon_area(points)
      points.each_with_index.sum { |point, index| next_point = points[(index + 1) % points.length]; point[0] * next_point[1] - next_point[0] * point[1] } / 2.0
    end

    def self.node_index(nodes, point)
      found = nodes.index { |candidate| distance(candidate, point) <= TOLERANCE_MM[:point] }
      return found if found
      nodes << point
      nodes.length - 1
    end

    def self.edge_components(edges, node_count)
      visited = {}
      components = []
      edges.each_index do |start|
        next if visited[start]
        stack = [start]
        component = []
        until stack.empty?
          current = stack.pop
          next if visited[current]
          visited[current] = true
          component << current
          a, b = edges[current]
          edges.each_index { |index| stack << index if !visited[index] && (edges[index][0] == a || edges[index][1] == a || edges[index][0] == b || edges[index][1] == b) }
        end
        components << component
      end
      components
    end

    def self.order_cycle(component, edges)
      first = component.first
      start_node = edges[first][0]
      current_node = edges[first][1]
      ordered = [[first, true]]
      used = { first => true }
      while current_node != start_node && ordered.length <= component.length
        next_edge = component.find { |index| !used[index] && (edges[index][0] == current_node || edges[index][1] == current_node) }
        return nil unless next_edge
        forward = edges[next_edge][0] == current_node
        current_node = forward ? edges[next_edge][1] : edges[next_edge][0]
        ordered << [next_edge, forward]
        used[next_edge] = true
      end
      current_node == start_node && ordered.length == component.length ? ordered : nil
    end

    def self.self_intersects?(points)
      points.each_with_index.any? do |point, index|
        points.each_with_index.any? do |other, other_index|
          other_index > index + 1 && !(index.zero? && other_index == points.length - 1) &&
            distance(point, other) <= TOLERANCE_MM[:point]
        end
      end || polygon_edges_self_intersect?(points)
    end

    def self.polygon_edges_self_intersect?(points)
      segments = points.each_index.map { |index| [points[index], points[(index + 1) % points.length]] }
      segments.each_with_index.any? do |one, i|
        segments.each_with_index.any? do |two, j|
          next false if (i - j).abs <= 1 || (i.zero? && j == segments.length - 1) || (j.zero? && i == segments.length - 1)
          cross2(one[0], one[1], two[0], two[1]) ||
            [one[0], one[1]].any? { |point| point_on_segment_interior?(point, two[0], two[1]) } ||
            [two[0], two[1]].any? { |point| point_on_segment_interior?(point, one[0], one[1]) }
        end
      end
    end

    def self.cross2(a, b, c, d)
      orient = ->(p, q, r) { (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]) }
      orient.call(a, b, c) * orient.call(a, b, d) < 0 && orient.call(c, d, a) * orient.call(c, d, b) < 0
    end

    def self.baseline_crossing?(a, b, c, d)
      return false if [a, b].any? { |point| [c, d].any? { |other| distance(point, other) <= TOLERANCE_MM[:point] } }
      return true if cross2(a, b, c, d)
      [a, b].any? { |point| point_on_segment_interior?(point, c, d) } ||
        [c, d].any? { |point| point_on_segment_interior?(point, a, b) }
    end

    def self.point_on_segment_interior?(point, start, finish)
      dx = finish[0] - start[0]
      dy = finish[1] - start[1]
      length_squared = dx * dx + dy * dy
      return false if length_squared <= 0
      cross = (point[0] - start[0]) * dy - (point[1] - start[1]) * dx
      return false if cross.abs > TOLERANCE_MM[:point] * Math.sqrt(length_squared)
      projection = ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length_squared
      projection > 1e-9 && projection < 1.0 - 1e-9
    end
  end
end
