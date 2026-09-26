require 'json'
require 'digest'

module HomeCAD
  module KitchenData
    KEY = 'kitchen_params_json'.freeze

    def self.read(entity)
      raw = Metadata.read(entity)[KEY]
      return {} unless raw.is_a?(String)

      data = JSON.parse(raw)
      raise JSON::ParserError unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Runtime::BridgeError.new(-32603, 'invalid_response', 'stored Kitchen parameters are malformed')
    end

    def self.write(entity, params)
      entity.set_attribute(Metadata::DICTIONARY, KEY, JSON.generate(canonical(params)))
      entity.set_attribute(Metadata::DICTIONARY, 'wall_id', params['wall_id'])
      WallAttachment.sync!(entity, placement: {
        'mode' => 'wall', 'wall_id' => params['wall_id'],
        'offset_mm' => params['start_mm'], 'bottom_mm' => 0.0,
        'side' => params['side'], 'clearance_mm' => params['clearance_mm']
      }, span_u_mm: params['span_mm'], span_z_mm: params['top_mm'])
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key.to_s, canonical(value[key])] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end
  end

  module Kitchen
    CAPABILITY = 'kitchen.run.v1'.freeze
    MAX_MODULES = 32
    TOLERANCE_MM = 0.01
    TYPES = {
      'base_shelves' => 'base', 'base_drawers' => 'base', 'sink' => 'base',
      'hob' => 'base', 'dishwasher' => 'base', 'oven' => 'base',
      'wall_shelves' => 'wall', 'wall_lift_front' => 'wall',
      'tall_storage' => 'tall', 'fridge' => 'tall'
    }.freeze
    DEFAULTS = {
      'base' => [560.0, 720.0, 100.0],
      'wall' => [350.0, 720.0, 1400.0],
      'tall' => [600.0, 2100.0, 0.0]
    }.freeze
    INPUT_KEYS = %w[wall wall_id start_mm end_mm side modules clearance_mm
                    filler_max_mm countertop countertop_thickness_mm plinth name].freeze

    def self.dispatch(model, method, params)
      case method
      when 'plan_kitchen_run' then plan(model, params)
      when 'apply_kitchen_run' then apply(model, params)
      when 'validate_kitchen' then validate(model, params)
      when 'update_kitchen_run' then update(model, params)
      when 'delete_kitchen_run' then delete(model, params)
      else raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "unknown kitchen method: #{method}")
      end
    end

    def self.plan(model, input, exclude_id: nil)
      Primitives.check_keys!(input, INPUT_KEYS)
      selector = input['wall'] || { 'homecad_id' => input['wall_id'] }
      wall, wall_params, wall_metadata = Architecture.wall_entity!(model, selector)
      frame, = Architecture.validate_wall_params!(wall_params)
      wall_id = wall_metadata['homecad_id']
      start_mm = number(input['start_mm'], 'start_mm')
      end_mm = number(input['end_mm'], 'end_mm')
      invalid!('start_mm must precede end_mm') unless end_mm > start_mm + TOLERANCE_MM
      constraint!('run must fit on the wall') if start_mm < -TOLERANCE_MM || end_mm > frame.length_mm + TOLERANCE_MM
      side = input['side']
      invalid!('side must be positive_v or negative_v') unless WallAttachment::SIDES.include?(side)
      modules = input['modules']
      invalid!("modules must contain 1..#{MAX_MODULES} entries") unless modules.is_a?(Array) && (1..MAX_MODULES).cover?(modules.length)
      tier = nil
      seen = []
      normalized = modules.map.with_index do |item, index|
        invalid!("modules[#{index}] must be an object") unless item.is_a?(Hash)
        Primitives.check_keys!(item, %w[key type width_mm depth_mm height_mm bottom_mm])
        kind = item['type']
        invalid!("unsupported module type: #{kind.inspect}") unless TYPES.key?(kind)
        current_tier = TYPES[kind]
        tier ||= current_tier
        constraint!('one run must use a single tier') unless tier == current_tier
        key = item['key']
        invalid!('module keys must be unique nonempty strings of at most 64 characters') unless key.is_a?(String) && !key.empty? && key.length <= 64 && !seen.include?(key)
        seen << key
        depth, height, bottom = DEFAULTS.fetch(tier)
        width = Geometry.positive_length(item['width_mm'], "modules[#{index}].width_mm")
        depth = Geometry.positive_length(item.fetch('depth_mm', depth), "modules[#{index}].depth_mm")
        height = Geometry.positive_length(item.fetch('height_mm', height), "modules[#{index}].height_mm")
        bottom = number(item.fetch('bottom_mm', bottom), "modules[#{index}].bottom_mm")
        constraint!('module bottom must be nonnegative') if bottom.negative?
        constraint!('module width and height must exceed 36 mm for the Cabinet case') if width <= 36 || height <= 36
        { 'key' => key, 'type' => kind, 'width_mm' => width,
          'depth_mm' => depth, 'height_mm' => height, 'bottom_mm' => bottom }
      end
      if tier == 'base' && normalized.map { |item| item['bottom_mm'] + item['height_mm'] }.uniq.length > 1
        constraint!('base module tops must align for one countertop')
      end
      clearance = number(input.fetch('clearance_mm', 0), 'clearance_mm')
      filler_max = number(input.fetch('filler_max_mm', 150), 'filler_max_mm')
      countertop_thickness = Geometry.positive_length(input.fetch('countertop_thickness_mm', 38), 'countertop_thickness_mm')
      constraint!('clearance_mm and filler_max_mm must be nonnegative') if clearance.negative? || filler_max.negative?
      invalid!('countertop must be a boolean') unless [true, false].include?(input.fetch('countertop', tier == 'base'))
      invalid!('plinth must be a boolean') unless [true, false].include?(input.fetch('plinth', tier == 'base'))
      countertop = input.fetch('countertop', tier == 'base')
      plinth = input.fetch('plinth', tier == 'base')
      constraint!('countertop and plinth are only supported for base runs') if tier != 'base' && (countertop || plinth)
      constraint!('plinth requires module depth above 40 mm') if plinth && normalized.any? { |item| item['depth_mm'] <= 40 }
      name = input.fetch('name', 'Kitchen run')
      invalid!('name must be a nonempty string of at most 128 characters') unless name.is_a?(String) && !name.strip.empty? && name.length <= 128

      positions = []
      cursor = start_mm
      normalized.each do |item|
        positions << { 'key' => item['key'], 'type' => item['type'], 'offset_mm' => cursor,
                       'width_mm' => item['width_mm'], 'bottom_mm' => item['bottom_mm'],
                       'height_mm' => item['height_mm'] }
        cursor += item['width_mm']
      end
      remaining = end_mm - cursor
      conflicts = []
      conflicts << conflict('negative_filler', 'modules exceed the available wall range') if remaining < -TOLERANCE_MM
      filler = remaining.positive? && remaining <= filler_max ? remaining : 0.0
      span = cursor - start_mm + filler
      top = normalized.map { |item| item['bottom_mm'] + item['height_mm'] }.max
      top += countertop_thickness if countertop
      constraint!('run must fit below wall top') if top > wall_params['height_mm'] + TOLERANCE_MM
      canonical = { 'wall_id' => wall_id, 'start_mm' => start_mm, 'end_mm' => end_mm,
        'side' => side, 'modules' => normalized, 'clearance_mm' => clearance,
        'filler_max_mm' => filler_max, 'countertop' => countertop,
        'countertop_thickness_mm' => countertop_thickness, 'plinth' => plinth,
        'name' => name, 'tier' => tier, 'span_mm' => span, 'top_mm' => top }
      conflicts.concat(scene_conflicts(model, canonical, positions, exclude_id: exclude_id))
      warnings = []
      warnings << 'remaining wall space is unallocated' if remaining > filler_max + TOLERANCE_MM
      warnings << 'base run has no countertop' if tier == 'base' && !countertop
      result = { 'params' => canonical, 'wall_revision' => wall_metadata['revision'],
        'positions' => positions, 'filler_mm' => filler, 'remaining_mm' => [remaining - filler, 0.0].max,
        'warnings' => warnings, 'conflicts' => conflicts, 'units' => 'mm' }
      result['fingerprint'] = Digest::SHA256.hexdigest(JSON.generate(KitchenData.canonical(result)))
      result
    end

    def self.scene_conflicts(model, params, positions, exclude_id: nil)
      wall_id = params['wall_id']; side = params['side']
      conflicts = []
      occupied = positions.map do |position|
        position.merge('height_mm' => position['height_mm'] +
          (params['countertop'] ? params['countertop_thickness_mm'] : 0.0))
      end
      filler_start = params['start_mm'] + positions.sum { |position| position['width_mm'] }
      filler_width = params['span_mm'] - positions.sum { |position| position['width_mm'] }
      if filler_width > TOLERANCE_MM
        occupied << { 'key' => 'filler', 'offset_mm' => filler_start,
          'width_mm' => filler_width, 'bottom_mm' => 0.0, 'height_mm' => params['top_mm'] }
      end
      Architecture.hosted_for(model, wall_id).each do |entity|
        metadata = Metadata.read(entity)
        next unless Architecture::HOSTED_TYPES.include?(metadata['type'])
        cut = ArchitectureData.read_params(entity)
        occupied.each do |position|
          next unless overlap?(position['offset_mm'], position['width_mm'], cut['offset_mm'], cut['width_mm'])
          next unless overlap?(position['bottom_mm'], position['height_mm'], cut.fetch('bottom_mm', 0), cut['height_mm'])
          next if metadata['type'] == 'architecture.niche' && cut['side'] != side

          conflicts << conflict('wall_cut_collision', "module #{position['key']} overlaps #{metadata['type']}",
                                position['key'], metadata['homecad_id'])
        end
      end
      WallAttachment.dependents_for(model, wall_id).each do |entity|
        data = Metadata.read(entity)
        next if data['homecad_id'] == exclude_id
        attached = WallAttachment.read(entity)
        next unless attached['side'] == side
        occupied.each do |position|
          next unless overlap?(position['offset_mm'], position['width_mm'], attached['offset_mm'], attached['span_u_mm'])
          next unless overlap?(position['bottom_mm'], position['height_mm'], attached['bottom_mm'], attached['span_z_mm'])

          conflicts << conflict('cabinet_collision', "module #{position['key']} overlaps a wall attachment",
                                position['key'], data['homecad_id'])
        end
      end
      conflicts
    end

    def self.overlap?(a, aw, b, bw)
      a.is_a?(Numeric) && aw.is_a?(Numeric) && b.is_a?(Numeric) && bw.is_a?(Numeric) &&
        [a, b].max < [a + aw, b + bw].min - TOLERANCE_MM
    end

    def self.conflict(code, message, module_key = nil, object_id = nil)
      { 'code' => code, 'message' => message, 'module_key' => module_key, 'object_id' => object_id }
    end

    def self.apply(model, request)
      Primitives.check_keys!(request, %w[plan])
      supplied = request['plan']
      invalid!('plan must be an object from plan_kitchen_run') unless supplied.is_a?(Hash) && supplied['params'].is_a?(Hash)
      fresh = plan(model, editable_input(supplied['params']))
      constraint!('kitchen plan is stale or changed; plan again') unless supplied == fresh
      constraint!('kitchen plan has conflicts') unless fresh['conflicts'].empty?
      values = fresh['params']
      wall, = Architecture.wall_entity!(model, { 'homecad_id' => values['wall_id'] })
      Architecture.require_mutable!(wall)
      Operation.run('Apply kitchen run', model: model) do
        root = model.entities.add_group
        Primitives.geometry_created!(root, 'SketchUp could not create KitchenRun Group')
        root.name = values['name']
        Metadata.create!(root, type: 'kitchen.run')
        KitchenData.write(root, values)
        root.transformation = run_transform(model, values)
        build_geometry!(model, root, values, fresh)
        MutationResult.success(operation: 'apply_kitchen_run', created: [serialize(root)], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "apply_kitchen_run failed: #{error.message}")
    end

    def self.run_transform(model, params)
      wall, wall_params, = Architecture.wall_entity!(model, { 'homecad_id' => params['wall_id'] })
      frame, normalized = Architecture.validate_wall_params!(wall_params)
      WallAttachment.wall_transform(frame, normalized['thickness_mm'], {
        'wall_id' => params['wall_id'], 'offset_mm' => params['start_mm'],
        'bottom_mm' => 0.0, 'side' => params['side'],
        'clearance_mm' => params['clearance_mm'], 'span_u_mm' => params['span_mm'],
        'span_z_mm' => params['top_mm']
      }, wall_height_mm: normalized['height_mm'])
    end

    def self.build_geometry!(model, root, values, plan_data)
      root.entities.clear!
      span = values['span_mm']
      plan_data['positions'].each do |position|
        module_data = values['modules'].find { |item| item['key'] == position['key'] }
        x = values['side'] == 'positive_v' ? position['offset_mm'] - values['start_mm'] :
          values['start_mm'] + span - position['offset_mm'] - position['width_mm']
        group = root.entities.add_group
        group.name = "#{module_data['type']}:#{module_data['key']}"
        group.set_attribute(Metadata::DICTIONARY, 'type', 'kitchen.module')
        group.set_attribute(Metadata::DICTIONARY, 'generated', true)
        group.set_attribute(Metadata::DICTIONARY, 'module_key', module_data['key'])
        group.set_attribute(Metadata::DICTIONARY, 'module_type', module_data['type'])
        group.transformation = Geom::Transformation.axes(
          Geometry.point_mm([x, 0.0, module_data['bottom_mm']], 'module_origin_mm'),
          Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(0, 1, 0),
          Geom::Vector3d.new(0, 0, 1))
        cabinet = Furniture.validate_params!(model, {
          'width_mm' => module_data['width_mm'], 'depth_mm' => module_data['depth_mm'],
          'height_mm' => module_data['height_mm'], 'detail_level' => 'concept'
        })
        Furniture.build_geometry!(group, cabinet)
      end
      if plan_data['filler_mm'] > TOLERANCE_MM
        x = values['side'] == 'positive_v' ? span - plan_data['filler_mm'] : 0.0
        box!(root, 'filler', x, 0, 0, plan_data['filler_mm'],
             values['modules'].map { |item| item['depth_mm'] }.max, values['top_mm'])
      end
      if values['countertop']
        top = values['modules'].first['bottom_mm'] + values['modules'].first['height_mm']
        box!(root, 'countertop', 0, 0, top, span,
             values['modules'].map { |item| item['depth_mm'] }.max + 20,
             values['countertop_thickness_mm'])
      end
      if values['plinth']
        lowest = values['modules'].map { |item| item['bottom_mm'] }.min
        box!(root, 'plinth', 0, 20, 0, span,
             values['modules'].map { |item| item['depth_mm'] }.max - 40, lowest) if lowest > TOLERANCE_MM
      end
      root
    end

    def self.box!(root, kind, x, y, z, width, depth, height)
      group = root.entities.add_group
      group.name = kind
      group.set_attribute(Metadata::DICTIONARY, 'type', "kitchen.#{kind}")
      group.set_attribute(Metadata::DICTIONARY, 'generated', true)
      px = Units.mm_to_internal(x); py = Units.mm_to_internal(y); pz = Units.mm_to_internal(z)
      dx = Units.mm_to_internal(width); dy = Units.mm_to_internal(depth); dz = Units.mm_to_internal(height)
      face = group.entities.add_face([
        Geom::Point3d.new(px, py, pz), Geom::Point3d.new(px + dx, py, pz),
        Geom::Point3d.new(px + dx, py + dy, pz), Geom::Point3d.new(px, py + dy, pz)
      ])
      Primitives.geometry_created!(face, "SketchUp could not create #{kind}")
      Furniture.extrude_to_positive_z!(face, dz, kind)
      group
    end

    def self.validate(model, request)
      Primitives.check_keys!(request, %w[target])
      root, values = resolve_run(model, request['target'])
      id = Metadata.read(root)['homecad_id']
      current = plan(model, editable_input(values), exclude_id: id)
      { 'homecad_id' => id, 'valid' => current['conflicts'].empty?,
        'conflicts' => current['conflicts'], 'warnings' => current['warnings'],
        'module_count' => values['modules'].length, 'units' => 'mm' }
    end

    def self.update(model, request)
      Primitives.check_keys!(request, %w[target changes])
      root, current = resolve_run(model, request['target'])
      Architecture.require_mutable!(root)
      changes = request['changes']
      invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      Primitives.check_keys!(changes, INPUT_KEYS - %w[wall wall_id])
      input = editable_input(current)
      proposed = plan(model, input.merge(changes), exclude_id: Metadata.read(root)['homecad_id'])
      constraint!('updated run has conflicts') unless proposed['conflicts'].empty?
      values = proposed['params']
      wall, = Architecture.wall_entity!(model, { 'homecad_id' => values['wall_id'] })
      Architecture.require_mutable!(wall)
      revision = Metadata.read(root)['revision']
      return MutationResult.success(operation: 'update_kitchen_run', updated: [serialize(root)], revision: revision) if KitchenData.canonical(current) == KitchenData.canonical(values)

      Operation.run('Update kitchen run', model: model) do
        KitchenData.write(root, values)
        root.name = values['name']
        root.transformation = run_transform(model, values)
        build_geometry!(model, root, values, proposed)
        Metadata.increment_revision!(root)
        MutationResult.success(operation: 'update_kitchen_run', updated: [serialize(root)],
                               revision: Metadata.read(root)['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "update_kitchen_run failed: #{error.message}")
    end

    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target])
      root, = resolve_run(model, request['target'])
      Architecture.require_mutable!(root)
      tombstone = serialize(root)
      revision = Metadata.read(root)['revision']
      Operation.run('Delete kitchen run', model: model) do
        model.entities.erase_entities(root)
        MutationResult.success(operation: 'delete_kitchen_run', deleted: [tombstone], revision: revision)
      end
    end

    def self.resolve_run(model, selector)
      entry = Targeting.resolve_one(model, selector)
      root = entry.entity
      constraint!('target must be a root-level KitchenRun') unless entry.parent.nil? &&
        root.is_a?(Sketchup::Group) && Metadata.read(root)['type'] == 'kitchen.run'
      [root, KitchenData.read(root)]
    end

    def self.serialize(entity)
      Serializer.serialize(Scene::Entry.new(entity: entity, parent: nil,
        path: [Scene.id(entity)], transform: nil), level: 'detailed')
    end

    def self.number(value, label) = Geometry.finite_number(value, label)
    def self.editable_input(values)
      values.reject { |key, _| %w[tier span_mm top_mm].include?(key) }
    end
    def self.invalid!(message) = Primitives.invalid!(message)
    def self.constraint!(message) = Architecture.constraint!(message)
  end
end
