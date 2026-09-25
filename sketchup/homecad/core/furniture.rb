module HomeCAD
  class FurnitureFrame
    attr_reader :origin_mm, :x_axis, :y_axis, :z_axis, :width_mm, :depth_mm, :height_mm

    def initialize(origin_mm:, x_axis:, y_axis:, width_mm:, depth_mm:, height_mm:)
      @origin_mm = origin_mm.freeze
      @x_axis = x_axis.freeze
      @y_axis = y_axis.freeze
      @z_axis = [0.0, 0.0, 1.0].freeze
      @width_mm = width_mm
      @depth_mm = depth_mm
      @height_mm = height_mm
    end

    def local_to_world(x_mm, y_mm, z_mm)
      3.times.map do |index|
        origin_mm[index] + x_axis[index] * x_mm + y_axis[index] * y_mm + z_axis[index] * z_mm
      end
    end

    def to_h(homecad_id:, params:)
      { 'homecad_id' => homecad_id, 'origin_mm' => origin_mm, 'x_axis' => x_axis,
        'y_axis' => y_axis, 'z_axis' => z_axis, 'width_mm' => width_mm,
        'depth_mm' => depth_mm, 'height_mm' => height_mm,
        'placement' => params['placement'] }
    end
  end

  module Furniture
    MAX_SHELVES = 32
    MAX_FRONTS = 32
    MAX_NAME_LENGTH = 128
    SIDES = %w[positive_v negative_v].freeze
    DETAIL_LEVELS = %w[concept construction].freeze
    TYPES = %w[furniture.cabinet].freeze
    CREATE_KEYS = %w[width_mm depth_mm height_mm panel_thickness_mm back_thickness_mm
                     shelf_z_mm fronts detail_level placement name].freeze
    CHANGE_KEYS = (CREATE_KEYS - ['name'] + ['name']).freeze
    TOLERANCE_MM = 0.01

    def self.dispatch(model, method, params)
      case method
      when 'get_furniture_frame' then get_frame(model, params)
      when 'list_furniture_parts' then list_parts(model, params)
      when 'create_cabinet' then create_cabinet(model, params)
      when 'update_furniture_object' then update_object(model, params)
      when 'delete_furniture_object' then delete_object(model, params)
      else raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "unknown furniture method: #{method}")
      end
    end

    def self.validate_params!(model, input, defaults: nil)
      values = (defaults || {}).merge(input)
      %w[width_mm depth_mm height_mm].each do |key|
        values[key] = Geometry.positive_length(values[key], key)
      end
      values['panel_thickness_mm'] = Geometry.positive_length(values.fetch('panel_thickness_mm', 18), 'panel_thickness_mm')
      values['back_thickness_mm'] = Geometry.positive_length(values.fetch('back_thickness_mm', 4), 'back_thickness_mm')
      if values['panel_thickness_mm'] * 2 >= [values['width_mm'], values['height_mm']].min
        constraint!('panel_thickness_mm must be less than half the cabinet width and height')
      end
      constraint!('back_thickness_mm must be less than cabinet depth') if values['back_thickness_mm'] >= values['depth_mm']
      values['shelf_z_mm'] = validate_shelves!(values.fetch('shelf_z_mm', []), values)
      values['fronts'] = validate_fronts!(values.fetch('fronts', []), values)
      values['detail_level'] = values.fetch('detail_level', 'construction')
      invalid!('detail_level must be concept or construction') unless DETAIL_LEVELS.include?(values['detail_level'])
      values['name'] = values.fetch('name', 'Cabinet')
      unless values['name'].is_a?(String) && !values['name'].strip.empty? && values['name'].length <= MAX_NAME_LENGTH
        invalid!("name must be a nonempty string up to #{MAX_NAME_LENGTH} characters")
      end
      values['placement'] = validate_placement!(model, values.fetch('placement', {
        'mode' => 'world', 'origin_mm' => [0, 0, 0], 'rotation_degrees' => 0
      }), values)
      values
    end

    def self.validate_shelves!(shelves, params)
      invalid!('shelf_z_mm must be an array') unless shelves.is_a?(Array)
      invalid!("shelf_z_mm supports at most #{MAX_SHELVES} shelves") if shelves.length > MAX_SHELVES
      values = shelves.map { |z| Geometry.finite_number(z, 'shelf_z_mm[]') }
      panel = params.fetch('panel_thickness_mm', 18).to_f
      values.each do |z|
        constraint!('shelf must fit between cabinet top and bottom') if z < panel - TOLERANCE_MM || z + panel > params['height_mm'] - panel + TOLERANCE_MM
      end
      sorted = values.sort
      sorted.each_cons(2) do |left, right|
        constraint!('shelves may not overlap') if left + panel > right + TOLERANCE_MM
      end
      values
    end

    def self.validate_fronts!(fronts, params)
      invalid!('fronts must be an array') unless fronts.is_a?(Array)
      invalid!("fronts supports at most #{MAX_FRONTS} entries") if fronts.length > MAX_FRONTS
      normalized = fronts.map.with_index do |front, index|
        invalid!("fronts[#{index}] must be an object") unless front.is_a?(Hash)
        allowed = %w[key kind x_mm z_mm width_mm height_mm thickness_mm hinge]
        invalid!("unsupported front fields: #{(front.keys - allowed).join(', ')}") unless (front.keys - allowed).empty?
        key = front['key']
        invalid!("fronts[#{index}].key must be a nonempty string") unless key.is_a?(String) && !key.empty? && key.length <= 64
        kind = front.fetch('kind', 'door')
        invalid!("fronts[#{index}].kind must be door, drawer_front, or fixed_panel") unless %w[door drawer_front fixed_panel].include?(kind)
        hinge = front.fetch('hinge', kind == 'door' ? 'left' : 'none')
        invalid!("fronts[#{index}].hinge must be left, right, or none") unless %w[left right none].include?(hinge)
        x = Geometry.finite_number(front['x_mm'], "fronts[#{index}].x_mm")
        z = Geometry.finite_number(front['z_mm'], "fronts[#{index}].z_mm")
        width = Geometry.positive_length(front['width_mm'], "fronts[#{index}].width_mm")
        height = Geometry.positive_length(front['height_mm'], "fronts[#{index}].height_mm")
        thickness = Geometry.positive_length(front.fetch('thickness_mm', params.fetch('panel_thickness_mm', 18)), "fronts[#{index}].thickness_mm")
        constraint!("front '#{key}' must fit within cabinet width and height") if x < -TOLERANCE_MM || z < -TOLERANCE_MM || x + width > params['width_mm'] + TOLERANCE_MM || z + height > params['height_mm'] + TOLERANCE_MM
        { 'key' => key, 'kind' => kind, 'x_mm' => x, 'z_mm' => z,
          'width_mm' => width, 'height_mm' => height, 'thickness_mm' => thickness,
          'hinge' => hinge }
      end
      invalid!('front keys must be unique') unless normalized.map { |front| front['key'] }.uniq.length == normalized.length
      normalized.combination(2) do |a, b|
        overlap_x = [a['x_mm'], b['x_mm']].max < [a['x_mm'] + a['width_mm'], b['x_mm'] + b['width_mm']].min - TOLERANCE_MM
        overlap_z = [a['z_mm'], b['z_mm']].max < [a['z_mm'] + a['height_mm'], b['z_mm'] + b['height_mm']].min - TOLERANCE_MM
        constraint!('fronts may not overlap') if overlap_x && overlap_z
      end
      normalized
    end

    def self.validate_placement!(model, placement, params)
      invalid!('placement must be an object') unless placement.is_a?(Hash)
      case placement['mode']
      when 'world'
        invalid!('world placement fields are invalid') unless (placement.keys - %w[mode origin_mm rotation_degrees]).empty?
        origin = placement.fetch('origin_mm', [0, 0, 0])
        unless origin.is_a?(Array) && origin.length == 3 && origin.all? { |value| value.is_a?(Numeric) && value.finite? }
          invalid!('placement.origin_mm must be three finite coordinates')
        end
        angle = Geometry.finite_number(placement.fetch('rotation_degrees', 0), 'placement.rotation_degrees')
        { 'mode' => 'world', 'origin_mm' => origin.map(&:to_f), 'rotation_degrees' => angle }
      when 'wall'
        allowed = %w[mode wall_id offset_mm bottom_mm side clearance_mm]
        invalid!('wall placement fields are invalid') unless (placement.keys - allowed).empty?
        selector = placement['wall_id'].is_a?(String) ? { 'homecad_id' => placement['wall_id'] } : nil
        invalid!('wall placement requires a wall_id') unless selector
        wall, wall_params, = Architecture.wall_entity!(model, selector)
        Architecture.require_mutable!(wall)
        frame, normalized_wall = Architecture.validate_wall_params!(wall_params)
        offset = Geometry.finite_number(placement['offset_mm'], 'placement.offset_mm')
        bottom = Geometry.finite_number(placement.fetch('bottom_mm', 0), 'placement.bottom_mm')
        side = placement['side']
        invalid!('placement.side must be positive_v or negative_v') unless SIDES.include?(side)
        clearance = Geometry.finite_number(placement.fetch('clearance_mm', 0), 'placement.clearance_mm')
        constraint!('cabinet must fit within wall length and height') if offset < -TOLERANCE_MM || offset + params['width_mm'] > frame.length_mm + TOLERANCE_MM || bottom < -TOLERANCE_MM || bottom + params['height_mm'] > normalized_wall['height_mm'] + TOLERANCE_MM
        constraint!('clearance_mm must be nonnegative') if clearance < 0
        { 'mode' => 'wall', 'wall_id' => placement['wall_id'], 'offset_mm' => offset,
          'bottom_mm' => bottom, 'side' => side, 'clearance_mm' => clearance }
      else
        invalid!('placement.mode must be world or wall')
      end
    end

    def self.frame_for(model, params)
      placement = params['placement']
      if placement['mode'] == 'world'
        origin = placement['origin_mm']
        radians = placement['rotation_degrees'] * Math::PI / 180.0
        x_axis = [Math.cos(radians), Math.sin(radians), 0.0]
        y_axis = [-Math.sin(radians), Math.cos(radians), 0.0]
      else
        wall, wall_params, = Architecture.wall_entity!(model, { 'homecad_id' => placement['wall_id'] })
        wall_data = Metadata.read(wall)
        wall_frame, normalized = Architecture.validate_wall_params!(wall_params)
        half = normalized['thickness_mm'] / 2.0
        positive = placement['side'] == 'positive_v'
        u = placement['offset_mm'] + (positive ? 0.0 : params['width_mm'])
        v = positive ? half + placement['clearance_mm'] : -half - placement['clearance_mm']
        origin = wall_frame.local_to_world(u, v, placement['bottom_mm'])
        x_axis = wall_frame.u_axis.map { |component| positive ? component : -component }
        y_axis = wall_frame.v_axis.map { |component| positive ? component : -component }
      end
      FurnitureFrame.new(origin_mm: origin, x_axis: x_axis, y_axis: y_axis,
                         width_mm: params['width_mm'], depth_mm: params['depth_mm'], height_mm: params['height_mm'])
    end

    def self.transformation(frame)
      Geom::Transformation.axes(Geometry.point_mm(frame.origin_mm, 'cabinet.origin_mm'),
        Geom::Vector3d.new(*frame.x_axis), Geom::Vector3d.new(*frame.y_axis), Geom::Vector3d.new(*frame.z_axis))
    end

    def self.part_schedule(params)
      width = params['width_mm']; depth = params['depth_mm']; height = params['height_mm']
      panel = params['panel_thickness_mm']; back = params['back_thickness_mm']
      parts = [
        { 'part_key' => 'left_side', 'part_kind' => 'carcass_panel', 'quantity' => 1,
          'width_mm' => depth, 'height_mm' => height, 'thickness_mm' => panel,
          'origin_mm' => [0.0, 0.0, 0.0] },
        { 'part_key' => 'right_side', 'part_kind' => 'carcass_panel', 'quantity' => 1,
          'width_mm' => depth, 'height_mm' => height, 'thickness_mm' => panel,
          'origin_mm' => [width - panel, 0.0, 0.0] },
        { 'part_key' => 'bottom', 'part_kind' => 'carcass_panel', 'quantity' => 1,
          'width_mm' => width - 2 * panel, 'height_mm' => depth, 'thickness_mm' => panel,
          'origin_mm' => [panel, 0.0, 0.0] },
        { 'part_key' => 'top', 'part_kind' => 'carcass_panel', 'quantity' => 1,
          'width_mm' => width - 2 * panel, 'height_mm' => depth, 'thickness_mm' => panel,
          'origin_mm' => [panel, 0.0, height - panel] },
        { 'part_key' => 'back', 'part_kind' => 'back_panel', 'quantity' => 1,
          'width_mm' => width - 2 * panel, 'height_mm' => height - 2 * panel, 'thickness_mm' => back,
          'origin_mm' => [panel, 0.0, panel] }
      ]
      params['shelf_z_mm'].each_with_index do |z, index|
        parts << { 'part_key' => "shelf:#{index}", 'part_kind' => 'shelf', 'quantity' => 1,
          'width_mm' => width - 2 * panel, 'height_mm' => depth - back, 'thickness_mm' => panel,
          'origin_mm' => [panel, back, z] }
      end
      params['fronts'].each do |front|
        parts << { 'part_key' => "front:#{front['key']}", 'part_kind' => front['kind'], 'quantity' => 1,
          'width_mm' => front['width_mm'], 'height_mm' => front['height_mm'],
          'thickness_mm' => front['thickness_mm'], 'origin_mm' => [front['x_mm'], depth, front['z_mm']],
          'hinge' => front['hinge'] }
      end
      parts
    end

    def self.build_geometry!(group, params)
      group.entities.clear!
      return build_concept!(group, params) if params['detail_level'] == 'concept'

      part_schedule(params).each { |part| create_part!(group, part) }
      group
    end

    def self.build_concept!(group, params)
      x = params['width_mm']; y = params['depth_mm']; z = params['height_mm']
      surfaces = [
        [[0, 0, 0], [0, y, 0], [0, y, z], [0, 0, z]],
        [[x, 0, 0], [x, 0, z], [x, y, z], [x, y, 0]],
        [[0, 0, 0], [x, 0, 0], [x, y, 0], [0, y, 0]],
        [[0, 0, z], [0, y, z], [x, y, z], [x, 0, z]],
        [[0, 0, 0], [0, 0, z], [x, 0, z], [x, 0, 0]],
        [[0, y, 0], [x, y, 0], [x, y, z], [0, y, z]]
      ]
      surfaces.each do |points|
        face = group.entities.add_face(points.map { |point| Geometry.point_mm(point, 'cabinet.surface') })
        Primitives.geometry_created!(face, 'SketchUp could not create concept cabinet surface')
      end
      params['fronts'].each do |front|
        points = [[front['x_mm'], y, front['z_mm']],
                  [front['x_mm'] + front['width_mm'], y, front['z_mm']],
                  [front['x_mm'] + front['width_mm'], y, front['z_mm'] + front['height_mm']],
                  [front['x_mm'], y, front['z_mm'] + front['height_mm']]]
        face = group.entities.add_face(points.map { |point| Geometry.point_mm(point, 'cabinet.front') })
        Primitives.geometry_created!(face, 'SketchUp could not create concept cabinet front')
      end
      group
    end

    def self.create_part!(root, part)
      collection = root.entities.add_group
      Primitives.geometry_created!(collection, 'SketchUp could not create cabinet part Group')
      collection.name = part['part_key']
      dictionary = Metadata::DICTIONARY
      collection.set_attribute(dictionary, 'generated', true)
      collection.set_attribute(dictionary, 'type', 'furniture.part')
      collection.set_attribute(dictionary, 'schema_version', Metadata::SCHEMA_VERSION)
      collection.set_attribute(dictionary, 'revision', 1)
      collection.set_attribute(dictionary, 'part_key', part['part_key'])
      collection.set_attribute(dictionary, 'part_kind', part['part_kind'])
      x, y, z = part['origin_mm']
      sx = part['width_mm']; sy = part['height_mm']; sz = part['thickness_mm']
      if part['part_key'].end_with?('_side')
        # Side panel plane is X/Z; its depth dimension occupies local Y.
        sx, sy, sz = part['thickness_mm'], part['width_mm'], part['height_mm']
        x = part['part_key'] == 'right_side' ? root_width_mm(root) - part['thickness_mm'] : 0.0
        y = 0.0; z = 0.0
      elsif part['part_key'] == 'bottom' || part['part_key'] == 'top'
        sx, sy, sz = part['width_mm'], part['height_mm'], part['thickness_mm']
      elsif part['part_key'] == 'back'
        sx, sy, sz = part['width_mm'], part['thickness_mm'], part['height_mm']
      elsif part['part_kind'] == 'shelf'
        sx, sy, sz = part['width_mm'], part['height_mm'], part['thickness_mm']
      else
        sx, sy, sz = part['width_mm'], part['thickness_mm'], part['height_mm']
      end
      ox = Units.mm_to_internal(x); oy = Units.mm_to_internal(y); oz = Units.mm_to_internal(z)
      dx = Units.mm_to_internal(sx); dy = Units.mm_to_internal(sy); dz = Units.mm_to_internal(sz)
      base = [Geom::Point3d.new(ox, oy, oz), Geom::Point3d.new(ox + dx, oy, oz),
              Geom::Point3d.new(ox + dx, oy + dy, oz), Geom::Point3d.new(ox, oy + dy, oz)]
      face = collection.entities.add_face(base)
      Primitives.geometry_created!(face, "SketchUp could not create cabinet part #{part['part_key']}")
      extrude_to_positive_z!(face, dz, part['part_key'])
      collection
    end

    def self.extrude_to_positive_z!(face, distance, part_key)
      normal_z = face.normal.z
      unless normal_z.is_a?(Numeric) && normal_z.finite? && normal_z.abs > 1e-9
        raise Runtime::BridgeError.new(-32009, 'geometry_error',
          "cabinet part #{part_key} base face is not horizontal")
      end

      face.pushpull(normal_z.positive? ? distance : -distance)
    end

    def self.root_width_mm(root)
      params = FurnitureData.read_params(root)
      params.fetch('width_mm', 0).to_f
    end

    def self.get_frame(model, params)
      Primitives.check_keys!(params, %w[target])
      entity, values = resolve_cabinet(model, params['target'])
      frame_for(model, values).to_h(homecad_id: Metadata.read(entity)['homecad_id'], params: values)
    end

    def self.list_parts(model, params)
      Primitives.check_keys!(params, %w[target])
      _entity, values = resolve_cabinet(model, params['target'])
      { 'detail_level' => values['detail_level'], 'parts' => part_schedule(values),
        'count' => part_schedule(values).length, 'units' => 'mm' }
    end

    def self.create_cabinet(model, params)
      Primitives.check_keys!(params, CREATE_KEYS)
      values = validate_params!(model, params)
      frame = frame_for(model, values)
      Operation.run('Create cabinet', model: model) do
        group = model.entities.add_group
        Primitives.geometry_created!(group, 'SketchUp could not create a cabinet Group')
        group.name = values['name']
        group.transformation = transformation(frame)
        Metadata.create!(group, type: 'furniture.cabinet')
        FurnitureData.write(group, params: values)
        build_geometry!(group, values)
        mutation_result('create_cabinet', created: [group], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('create_cabinet', error)
    end

    def self.update_object(model, params)
      Primitives.check_keys!(params, %w[target changes])
      entity, current = resolve_cabinet(model, params['target'])
      require_mutable!(entity)
      changes = params['changes']
      invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      invalid!("unsupported changes: #{(changes.keys - CHANGE_KEYS).join(', ')}") unless (changes.keys - CHANGE_KEYS).empty?
      proposed = validate_params!(model, changes, defaults: current)
      new_transform = transformation(frame_for(model, proposed))
      old_frame = frame_for(model, current)
      old_transform = transformation(old_frame)
      placement_changed = !WallAttachment.transformations_equal?(old_transform, new_transform)
      geometry_changed = %w[width_mm depth_mm height_mm panel_thickness_mm back_thickness_mm shelf_z_mm fronts detail_level].any? do |key|
        current[key] != proposed[key]
      end
      Operation.run('Update cabinet', model: model) do
        FurnitureData.write(entity, params: proposed)
        entity.transformation = new_transform if placement_changed
        build_geometry!(entity, proposed) if geometry_changed
        entity.name = proposed['name']
        Metadata.increment_revision!(entity) if geometry_changed || placement_changed || current['name'] != proposed['name']
        mutation_result('update_furniture_object', updated: [entity], revision: Metadata.read(entity)['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('update_furniture_object', error)
    end

    def self.delete_object(model, params)
      Primitives.check_keys!(params, %w[target])
      entity, = resolve_cabinet(model, params['target'])
      require_mutable!(entity)
      tombstone = serialize_entity(entity)
      metadata = Metadata.read(entity)
      Operation.run('Delete cabinet', model: model) do
        model.entities.erase_entities(entity)
        MutationResult.success(operation: 'delete_furniture_object', deleted: [tombstone], revision: metadata['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      geometry_error!('delete_furniture_object', error)
    end

    def self.resolve_cabinet(model, selector)
      entry = Targeting.resolve_one(model, selector)
      entity = entry.entity
      metadata = Metadata.read(entity)
      constraint!('target must be a root-level HomeCAD Cabinet Group') unless entry.parent.nil? && entity.is_a?(Sketchup::Group) && metadata['type'] == 'furniture.cabinet'
      [entity, FurnitureData.read_params(entity)]
    end

    def self.require_mutable!(entity)
      Architecture.require_mutable!(entity)
    end

    def self.mutation_result(operation, created: [], updated: [], deleted: [], revision:)
      MutationResult.success(operation: operation, created: created.map { |entity| serialize_entity(entity) },
        updated: updated.map { |entity| serialize_entity(entity) }, deleted: deleted, revision: revision)
    end

    def self.serialize_entity(entity)
      entry = Scene::Entry.new(entity: entity, parent: nil, path: [Scene.id(entity)], transform: nil)
      Serializer.serialize(entry, level: 'detailed')
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
  end
end
