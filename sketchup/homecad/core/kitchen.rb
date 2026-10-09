require 'json'
require 'digest'
require 'securerandom'

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
      if params['layout_type'] == 'l_shaped'
        entity.set_attribute(Metadata::DICTIONARY, KEY, JSON.generate(canonical(params)))
        MultiWallAttachment.sync!(entity, params['legs'].map { |leg| leg['wall_id'] })
        return
      end
      entity.set_attribute(Metadata::DICTIONARY, KEY, JSON.generate(canonical(params)))
      entity.set_attribute(Metadata::DICTIONARY, 'wall_id', params['wall_id'])
      WallAttachment.sync!(entity, placement: {
        'mode' => 'wall', 'wall_id' => params['wall_id'],
        'offset_mm' => params['run_start_mm'], 'bottom_mm' => 0.0,
        'side' => params['side'], 'clearance_mm' => params['clearance_mm']
      }, span_u_mm: params['span_mm'], span_z_mm: params['top_mm'])
    end

    def self.write_child(entity, record:, descriptor:, run_id:, wall_id:)
      Metadata.write(entity, type: descriptor['type'], generated: true,
        homecad_id: record['homecad_id'], revision: record['revision'])
      entity.set_attribute(Metadata::DICTIONARY, KEY, JSON.generate(canonical(descriptor['params'])))
      entity.set_attribute(Metadata::DICTIONARY, 'kitchen_run_id', run_id)
      entity.set_attribute(Metadata::DICTIONARY, 'wall_id', wall_id)
      if descriptor['params']['module_key']
        entity.set_attribute(Metadata::DICTIONARY, 'module_key', descriptor['params']['module_key'])
        entity.set_attribute(Metadata::DICTIONARY, 'module_type', descriptor['params']['module_type'])
      end
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
    MAX_SERVICE_CLEARANCE_MM = 5000.0
    TOLERANCE_MM = 0.01
    TYPES = {
      'base_shelves' => 'base', 'base_drawers' => 'base', 'sink' => 'base',
      'hob' => 'base', 'dishwasher' => 'base', 'oven' => 'base',
      'wall_shelves' => 'wall', 'wall_lift_front' => 'wall',
      'tall_storage' => 'tall', 'fridge' => 'tall'
    }.freeze
    APPLIANCE_TYPES = %w[hob dishwasher oven fridge].freeze
    DEFAULTS = {
      'base' => [560.0, 720.0, 100.0],
      'wall' => [350.0, 720.0, 1400.0],
      'tall' => [600.0, 2100.0, 0.0]
    }.freeze
    INPUT_KEYS = %w[wall wall_id start_mm end_mm start_clearance_mm end_clearance_mm
                    side modules clearance_mm filler_max_mm countertop
                    countertop_thickness_mm countertop_cutouts plinth constraints name].freeze
    CONSTRAINT_KEYS = %w[require_full_coverage require_countertop
                         min_opening_clearance_mm max_module_depth_mm
                         require_service_clearance].freeze

    def self.dispatch(model, method, params)
      case method
      when 'plan_kitchen_run' then plan(model, params)
      when 'apply_kitchen_run' then apply(model, params)
      when 'validate_kitchen' then validate(model, params)
      when 'update_kitchen_run' then update(model, params)
      when 'delete_kitchen_run' then delete(model, params)
      when 'plan_corner_kitchen_run' then CornerKitchen.plan(model, params)
      else raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "unknown kitchen method: #{method}")
      end
    end

    def self.plan(model, input, exclude_id: nil, preserve_legacy: false)
      Primitives.check_keys!(input, INPUT_KEYS)
      selector = input['wall'] || { 'homecad_id' => input['wall_id'] }
      wall, wall_params, wall_metadata = Architecture.wall_entity!(model, selector)
      frame, = Architecture.validate_wall_params!(wall_params)
      wall_id = wall_metadata['homecad_id']
      start_mm = number(input['start_mm'], 'start_mm')
      end_mm = number(input['end_mm'], 'end_mm')
      invalid!('start_mm must precede end_mm') unless end_mm > start_mm + TOLERANCE_MM
      constraint!('run must fit on the wall') if start_mm < -TOLERANCE_MM || end_mm > frame.length_mm + TOLERANCE_MM
      start_clearance = number(input.fetch('start_clearance_mm', 0), 'start_clearance_mm')
      end_clearance = number(input.fetch('end_clearance_mm', 0), 'end_clearance_mm')
      constraint!('start/end clearance must be nonnegative') if start_clearance.negative? || end_clearance.negative?
      run_start = start_mm + start_clearance
      available_end = end_mm - end_clearance
      constraint!('start/end clearances leave no available run') if available_end <= run_start + TOLERANCE_MM
      side = input['side']
      invalid!('side must be positive_v or negative_v') unless WallAttachment::SIDES.include?(side)
      modules = input['modules']
      invalid!("modules must contain 1..#{MAX_MODULES} entries") unless modules.is_a?(Array) && (1..MAX_MODULES).cover?(modules.length)
      tier = nil
      seen = []
      normalized = modules.map.with_index do |item, index|
        invalid!("modules[#{index}] must be an object") unless item.is_a?(Hash)
        Primitives.check_keys!(item, %w[key type width_mm depth_mm height_mm bottom_mm
                                       service_clearance_mm] + KitchenCabinetDefinition::FIELDS)
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
        value = { 'key' => key, 'type' => kind, 'width_mm' => width,
          'depth_mm' => depth, 'height_mm' => height, 'bottom_mm' => bottom }
        %w[material_id front_material_id].each do |field|
          value[field] = Furniture.validate_identifier(item[field], "modules[#{index}].#{field}") if item.key?(field)
        end
        KitchenCabinetDefinition.normalize!(model, value, item, preserve_legacy: preserve_legacy)
        if item.key?('service_clearance_mm')
          service = item['service_clearance_mm']
          invalid!('service_clearance_mm must be an object') unless service.is_a?(Hash)
          Primitives.check_keys!(service, ServiceZones::DIRECTIONS)
          normalized_service = ServiceZones::DIRECTIONS.to_h do |direction|
            amount = number(service.fetch(direction, 0), "modules[#{index}].service_clearance_mm.#{direction}")
            constraint!("#{direction} must be between 0 and #{MAX_SERVICE_CLEARANCE_MM} mm") if
              amount.negative? || amount > MAX_SERVICE_CLEARANCE_MM
            [direction, amount]
          end
          value['service_clearance_mm'] = normalized_service if normalized_service.values.any?(&:positive?)
        end
        value
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
      constraints = input.fetch('constraints', {})
      invalid!('constraints must be an object') unless constraints.is_a?(Hash)
      Primitives.check_keys!(constraints, CONSTRAINT_KEYS)
      full_coverage = constraints.fetch('require_full_coverage', false)
      required_countertop = constraints.fetch('require_countertop', tier == 'base')
      required_service = constraints.fetch('require_service_clearance', false)
      invalid!('coverage constraints must be boolean') unless [true, false].include?(full_coverage) &&
        [true, false].include?(required_countertop) && [true, false].include?(required_service)
      opening_clearance = number(constraints.fetch('min_opening_clearance_mm', 0), 'min_opening_clearance_mm')
      constraint!('min_opening_clearance_mm must be nonnegative') if opening_clearance.negative?
      max_depth = constraints['max_module_depth_mm']
      max_depth = Geometry.positive_length(max_depth, 'max_module_depth_mm') unless max_depth.nil?
      constraints = { 'require_full_coverage' => full_coverage,
        'require_countertop' => required_countertop,
        'min_opening_clearance_mm' => opening_clearance,
        'max_module_depth_mm' => max_depth }
      constraints['require_service_clearance'] = true if required_service
      name = input.fetch('name', 'Kitchen run')
      invalid!('name must be a nonempty string of at most 128 characters') unless name.is_a?(String) && !name.strip.empty? && name.length <= 128

      positions = []
      cursor = run_start
      normalized.each do |item|
        positions << { 'key' => item['key'], 'type' => item['type'], 'offset_mm' => cursor,
                       'width_mm' => item['width_mm'], 'bottom_mm' => item['bottom_mm'],
                       'height_mm' => item['height_mm'] }
        cursor += item['width_mm']
      end
      remaining = available_end - cursor
      conflicts = []
      conflicts << conflict('negative_filler', 'modules exceed the available wall range') if remaining < -TOLERANCE_MM
      filler = remaining.positive? && remaining <= filler_max ? remaining : 0.0
      span = cursor - run_start + filler
      conflicts << conflict('unallocated_space', 'run leaves more unallocated space than allowed') if
        full_coverage && remaining - filler > TOLERANCE_MM
      conflicts << conflict('countertop_missing_coverage', 'base modules require countertop coverage') if
        tier == 'base' && required_countertop && !countertop
      normalized.each do |item|
        next if max_depth.nil? || item['depth_mm'] <= max_depth + TOLERANCE_MM

        conflicts << conflict('module_depth_exceeded', "module #{item['key']} exceeds maximum depth", item['key'])
      end
      top = normalized.map { |item| item['bottom_mm'] + item['height_mm'] }.max
      top += countertop_thickness if countertop
      constraint!('run must fit below wall top') if top > wall_params['height_mm'] + TOLERANCE_MM
      canonical = { 'wall_id' => wall_id, 'start_mm' => start_mm, 'end_mm' => end_mm,
        'start_clearance_mm' => start_clearance, 'end_clearance_mm' => end_clearance,
        'run_start_mm' => run_start, 'constraints' => constraints,
        'side' => side, 'modules' => normalized, 'clearance_mm' => clearance,
        'filler_max_mm' => filler_max, 'countertop' => countertop,
        'countertop_thickness_mm' => countertop_thickness, 'plinth' => plinth,
        'name' => name, 'tier' => tier, 'span_mm' => span, 'top_mm' => top }
      cuts = CountertopCutouts.normalize(input.fetch('countertop_cutouts', []))
      constraint!('cutouts require an enabled base countertop') if cuts.any? && !countertop
      if cuts.any?
        canonical['countertop_cutouts'] = cuts
        CountertopCutouts.straight(canonical)
      end
      conflicts.concat(scene_conflicts(model, canonical, exclude_id: exclude_id))
      service_zones, service_findings, truncated = if normalized.any? { |item| item.key?('service_clearance_mm') }
        ServiceZones.check(model, canonical, exclude_run_id: exclude_id)
      else
        [[], [], false]
      end
      if required_service
        conflicts.concat(service_findings.map { |finding| finding.merge('message' =>
          "module #{finding['module_key']} has blocked #{finding['direction']} service clearance") })
      end
      conflicts << conflict('service_check_incomplete', 'service clearance check exceeded its result limit') if truncated
      warnings = []
      warnings << 'remaining wall space is unallocated' if remaining > filler_max + TOLERANCE_MM
      warnings << 'base run has no countertop' if tier == 'base' && !countertop
      warnings << "#{service_findings.length} service clearance obstruction(s); inspect service_findings" if
        service_findings.any? && !required_service
      result = { 'params' => canonical, 'wall_revision' => wall_metadata['revision'],
        'positions' => positions, 'filler_mm' => filler, 'remaining_mm' => [remaining - filler, 0.0].max,
        'warnings' => warnings, 'conflicts' => conflicts, 'service_zones' => service_zones,
        'service_findings' => service_findings, 'units' => 'mm' }
      result['fingerprint'] = Digest::SHA256.hexdigest(JSON.generate(KitchenData.canonical(result)))
      result
    end

    def self.scene_conflicts(model, params, exclude_id: nil)
      wall_id = params['wall_id']; side = params['side']
      conflicts = []
      occupied = occupied_rectangles(params)
      Architecture.hosted_for(model, wall_id).each do |entity|
        metadata = Metadata.read(entity)
        next unless Architecture::HOSTED_TYPES.include?(metadata['type'])
        cut = ArchitectureData.read_params(entity)
        occupied.each do |position|
          clearance = params['constraints']['min_opening_clearance_mm']
          next unless overlap?(position['offset_mm'], position['width_mm'],
                               cut['offset_mm'] - clearance, cut['width_mm'] + 2 * clearance)
          next unless overlap?(position['bottom_mm'], position['height_mm'], cut.fetch('bottom_mm', 0), cut['height_mm'])
          next if metadata['type'] == 'architecture.niche' && cut['side'] != side

          conflicts << conflict('wall_cut_collision', "module #{position['key']} overlaps #{metadata['type']}",
                                position['key'], metadata['homecad_id'], metadata['type'])
        end
      end
      WallAttachment.dependents_for(model, wall_id).each do |entity|
        data = Metadata.read(entity)
        next if data['homecad_id'] == exclude_id
        attached = WallAttachment.read(entity)
        next unless attached['side'] == side
        if data['type'] == 'kitchen.run'
          other = occupied_rectangles(KitchenData.read(entity))
          occupied.each do |position|
            other.each do |counterpart|
              next unless rectangles_overlap?(position, counterpart)

              code = if APPLIANCE_TYPES.include?(position['type']) || APPLIANCE_TYPES.include?(counterpart['type'])
                'appliance_collision'
              elsif position['tier'] == 'wall' || counterpart['tier'] == 'wall'
                'wall_cabinet_collision'
              else
                'cabinet_collision'
              end
              conflicts << conflict(code, "#{position['key']} overlaps #{counterpart['key']}",
                position['key'], data['homecad_id'], counterpart['key'])
            end
          end
          next
        end
        other_depth = data['type'] == 'furniture.cabinet' ?
          FurnitureData.read_params(entity)['depth_mm'] : nil
        counterpart = { 'offset_mm' => attached['offset_mm'], 'width_mm' => attached['span_u_mm'],
          'bottom_mm' => attached['bottom_mm'], 'height_mm' => attached['span_z_mm'],
          'depth_offset_mm' => attached['clearance_mm'], 'depth_mm' => other_depth }
        occupied.each do |position|
          next unless rectangles_overlap?(position, counterpart)

          conflicts << conflict('cabinet_collision', "module #{position['key']} overlaps a wall attachment",
                                position['key'], data['homecad_id'])
        end
      end
      MultiWallAttachment.dependents_for(model, wall_id).each do |entity|
        data = Metadata.read(entity)
        next if data['homecad_id'] == exclude_id

        frame = ServiceZones.frame_from_wall(Architecture.wall_entity!(model,
          { 'homecad_id' => wall_id })[1], side: side)
        other = CornerKitchen.occupied_boxes(model, KitchenData.read(entity))
        occupied.each do |position|
          volume = ServiceZones.box(*frame,
            [position['offset_mm'], position['offset_mm'] + position['width_mm'],
             position['depth_offset_mm'], position['depth_offset_mm'] + position['depth_mm'],
             position['bottom_mm'], position['bottom_mm'] + position['height_mm']])
          other.each do |key, box|
            next unless ServiceZones.overlap?(volume, box)

            conflicts << conflict('cabinet_collision',
              "module #{position['key']} overlaps corner KitchenRun #{key}",
              position['key'], data['homecad_id'], key)
          end
        end
      end
      conflicts
    end

    def self.occupied_rectangles(params)
      cursor = params.fetch('run_start_mm', params['start_mm'])
      clearance = params['clearance_mm']
      occupied = params['modules'].map do |item|
        rectangle = { 'key' => item['key'], 'type' => item['type'], 'tier' => params['tier'],
          'offset_mm' => cursor, 'width_mm' => item['width_mm'],
          'bottom_mm' => item['bottom_mm'], 'height_mm' => item['height_mm'],
          'depth_offset_mm' => clearance, 'depth_mm' => item['depth_mm'] }
        cursor += item['width_mm']
        rectangle
      end
      filler_width = params['span_mm'] - params['modules'].sum { |item| item['width_mm'] }
      max_depth = params['modules'].map { |item| item['depth_mm'] }.max
      if filler_width > TOLERANCE_MM
        occupied << { 'key' => 'filler', 'type' => 'filler', 'tier' => params['tier'],
          'offset_mm' => cursor, 'width_mm' => filler_width,
          'bottom_mm' => 0.0, 'height_mm' => params['top_mm'],
          'depth_offset_mm' => clearance, 'depth_mm' => max_depth }
      end
      if params['countertop']
        occupied << { 'key' => 'countertop', 'type' => 'countertop', 'tier' => params['tier'],
          'offset_mm' => params.fetch('run_start_mm', params['start_mm']),
          'width_mm' => params['span_mm'], 'bottom_mm' => params['modules'].first['bottom_mm'] + params['modules'].first['height_mm'],
          'height_mm' => params['countertop_thickness_mm'],
          'depth_offset_mm' => clearance, 'depth_mm' => max_depth + 20 }
      end
      lowest = params['modules'].map { |item| item['bottom_mm'] }.min
      if params['plinth'] && lowest > TOLERANCE_MM
        occupied << { 'key' => 'plinth', 'type' => 'plinth', 'tier' => params['tier'],
          'offset_mm' => params.fetch('run_start_mm', params['start_mm']),
          'width_mm' => params['span_mm'], 'bottom_mm' => 0.0, 'height_mm' => lowest,
          'depth_offset_mm' => clearance + 20, 'depth_mm' => max_depth - 40 }
      end
      occupied
    end

    def self.rectangles_overlap?(left, right)
      return false unless overlap?(left['offset_mm'], left['width_mm'], right['offset_mm'], right['width_mm']) &&
                          overlap?(left['bottom_mm'], left['height_mm'], right['bottom_mm'], right['height_mm'])
      return true unless right['depth_mm'].is_a?(Numeric)

      overlap?(left['depth_offset_mm'], left['depth_mm'], right['depth_offset_mm'], right['depth_mm'])
    end

    def self.overlap?(a, aw, b, bw)
      a.is_a?(Numeric) && aw.is_a?(Numeric) && b.is_a?(Numeric) && bw.is_a?(Numeric) &&
        [a, b].max < [a + aw, b + bw].min - TOLERANCE_MM
    end

    def self.conflict(code, message, module_key = nil, object_id = nil, other = nil)
      { 'code' => code, 'message' => message, 'module_key' => module_key,
        'object_id' => object_id, 'other' => other }
    end

    # Object keys are canonical across geometry regeneration. SketchUp child
    # persistent IDs can change, while these HomeCAD UUIDs survive updates.
    def self.object_descriptors(values)
      wall_id = values['wall_id']
      side = values['side']
      cursor = values.fetch('run_start_mm', values['start_mm'])
      descriptors = {}
      values['modules'].each do |item|
        key = "module:#{item['key']}"
        type = if APPLIANCE_TYPES.include?(item['type'])
          'kitchen.appliance'
        else
          "kitchen.#{values['tier']}_cabinet"
        end
        descriptors[key] = { 'type' => type, 'params' => item.merge(
          'module_key' => item['key'], 'module_type' => item['type'],
          'offset_mm' => cursor, 'wall_id' => wall_id, 'side' => side) }
        cursor += item['width_mm']
      end
      filler_width = values['span_mm'] - values['modules'].sum { |item| item['width_mm'] }
      if filler_width > TOLERANCE_MM
        descriptors['filler'] = { 'type' => 'kitchen.filler', 'params' => {
          'wall_id' => wall_id, 'side' => side, 'offset_mm' => cursor,
          'width_mm' => filler_width, 'height_mm' => values['top_mm'],
          'depth_mm' => values['modules'].map { |item| item['depth_mm'] }.max } }
      end
      if values['countertop']
        descriptors['countertop'] = { 'type' => 'kitchen.countertop', 'params' => {
          'wall_id' => wall_id, 'side' => side,
          'offset_mm' => values.fetch('run_start_mm', values['start_mm']),
          'width_mm' => values['span_mm'],
          'depth_mm' => values['modules'].map { |item| item['depth_mm'] }.max + 20,
          'bottom_mm' => values['modules'].first['bottom_mm'] + values['modules'].first['height_mm'],
          'height_mm' => values['countertop_thickness_mm'] } }
        if values.key?('countertop_cutouts')
          descriptors['countertop']['params']['cutouts'] = values['countertop_cutouts']
        end
      end
      lowest = values['modules'].map { |item| item['bottom_mm'] }.min
      if values['plinth'] && lowest > TOLERANCE_MM
        descriptors['plinth'] = { 'type' => 'kitchen.plinth', 'params' => {
          'wall_id' => wall_id, 'side' => side,
          'offset_mm' => values.fetch('run_start_mm', values['start_mm']),
          'width_mm' => values['span_mm'],
          'depth_mm' => values['modules'].map { |item| item['depth_mm'] }.max - 40,
          'height_mm' => lowest } }
      end
      descriptors
    end

    def self.assign_semantic_objects!(values, previous = nil)
      prior_records = previous.is_a?(Hash) ? previous.fetch('semantic_objects', {}) : {}
      prior_descriptors = previous.is_a?(Hash) ? object_descriptors(previous) : {}
      values['semantic_objects'] = object_descriptors(values).to_h do |key, descriptor|
        prior = prior_records[key]
        if prior.is_a?(Hash) && Metadata.uuid?(prior['homecad_id']) &&
           prior['revision'].is_a?(Integer) && prior['revision'].positive?
          changed = KitchenData.canonical(prior_descriptors[key]) != KitchenData.canonical(descriptor)
          [key, { 'homecad_id' => prior['homecad_id'],
                  'revision' => prior['revision'] + (changed ? 1 : 0) }]
        else
          [key, { 'homecad_id' => SecureRandom.uuid, 'revision' => 1 }]
        end
      end
      values
    end

    def self.apply(model, request)
      Primitives.check_keys!(request, %w[plan])
      supplied = request['plan']
      invalid!('plan must be an object from plan_kitchen_run') unless supplied.is_a?(Hash) && supplied['params'].is_a?(Hash)
      return CornerKitchen.apply(model, supplied) if supplied['params']['layout_type'] == 'l_shaped'
      fresh = plan(model, editable_input(supplied['params']), preserve_legacy: true)
      constraint!('kitchen plan is stale or changed; plan again') unless supplied == fresh
      constraint!('kitchen plan has conflicts') unless fresh['conflicts'].empty?
      values = fresh['params']
      wall, = Architecture.wall_entity!(model, { 'homecad_id' => values['wall_id'] })
      Architecture.require_mutable!(wall)
      assign_semantic_objects!(values)
      Operation.run('Apply kitchen run', model: model) do
        root = model.entities.add_group
        Primitives.geometry_created!(root, 'SketchUp could not create KitchenRun Group')
        root.name = values['name']
        Metadata.create!(root, type: 'kitchen.run')
        KitchenData.write(root, values)
        root.transformation = run_transform(model, values)
        build_geometry!(model, root, values, fresh)
        MutationResult.success(operation: 'apply_kitchen_run',
          created: [serialize(root)] + child_serializations(root), warnings: fresh['warnings'], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "apply_kitchen_run failed: #{error.message}")
    end

    def self.run_transform(model, params)
      wall, wall_params, = Architecture.wall_entity!(model, { 'homecad_id' => params['wall_id'] })
      frame, normalized = Architecture.validate_wall_params!(wall_params)
      WallAttachment.wall_transform(frame, normalized['thickness_mm'], {
        'wall_id' => params['wall_id'], 'offset_mm' => params['run_start_mm'],
        'bottom_mm' => 0.0, 'side' => params['side'],
        'clearance_mm' => params['clearance_mm'], 'span_u_mm' => params['span_mm'],
        'span_z_mm' => params['top_mm']
      }, wall_height_mm: normalized['height_mm'])
    end

    def self.build_geometry!(model, root, values, plan_data)
      root.entities.clear!
      span = values['span_mm']
      descriptors = object_descriptors(values)
      run_id = Metadata.read(root)['homecad_id']
      plan_data['positions'].each do |position|
        module_data = values['modules'].find { |item| item['key'] == position['key'] }
        x = values['side'] == 'positive_v' ? position['offset_mm'] - values['run_start_mm'] :
          values['run_start_mm'] + span - position['offset_mm'] - position['width_mm']
        group = root.entities.add_group
        group.name = "#{module_data['type']}:#{module_data['key']}"
        key = "module:#{module_data['key']}"
        KitchenData.write_child(group, record: values['semantic_objects'].fetch(key),
          descriptor: descriptors.fetch(key), run_id: run_id, wall_id: values['wall_id'])
        group.transformation = Geom::Transformation.axes(
          Geometry.point_mm([x, 0.0, module_data['bottom_mm']], 'module_origin_mm'),
          Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(0, 1, 0),
          Geom::Vector3d.new(0, 0, 1))
        KitchenCabinetDefinition.build!(model, group, module_data)
      end
      if plan_data['filler_mm'] > TOLERANCE_MM
        x = values['side'] == 'positive_v' ? span - plan_data['filler_mm'] : 0.0
        group = box!(root, 'filler', x, 0, 0, plan_data['filler_mm'],
                     values['modules'].map { |item| item['depth_mm'] }.max, values['top_mm'])
        KitchenData.write_child(group, record: values['semantic_objects'].fetch('filler'),
          descriptor: descriptors.fetch('filler'), run_id: run_id, wall_id: values['wall_id'])
      end
      if values['countertop']
        top = values['modules'].first['bottom_mm'] + values['modules'].first['height_mm']
        group = root.entities.add_group
        group.name = 'countertop'
        CountertopCutouts.build!(group, CountertopCutouts.straight(values), top, values['countertop_thickness_mm'])
        KitchenData.write_child(group, record: values['semantic_objects'].fetch('countertop'),
          descriptor: descriptors.fetch('countertop'), run_id: run_id, wall_id: values['wall_id'])
      end
      if values['plinth']
        lowest = values['modules'].map { |item| item['bottom_mm'] }.min
        if lowest > TOLERANCE_MM
          group = box!(root, 'plinth', 0, 20, 0, span,
                       values['modules'].map { |item| item['depth_mm'] }.max - 40, lowest)
          KitchenData.write_child(group, record: values['semantic_objects'].fetch('plinth'),
            descriptor: descriptors.fetch('plinth'), run_id: run_id, wall_id: values['wall_id'])
        end
      end
      root
    end

    def self.box!(root, kind, x, y, z, width, depth, height)
      group = root.entities.add_group
      group.name = kind
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
      return CornerKitchen.validate(model, root, values) if values['layout_type'] == 'l_shaped'
      id = Metadata.read(root)['homecad_id']
      current = plan(model, editable_input(values), exclude_id: id, preserve_legacy: true)
      { 'homecad_id' => id, 'valid' => current['conflicts'].empty?,
        'conflicts' => current['conflicts'], 'warnings' => current['warnings'],
        'service_zones' => current['service_zones'], 'service_findings' => current['service_findings'],
        'module_count' => values['modules'].length, 'units' => 'mm' }
    end

    def self.update(model, request)
      Primitives.check_keys!(request, %w[target changes])
      root, current = resolve_run(model, request['target'])
      return CornerKitchen.update(model, root, current, request['changes']) if current['layout_type'] == 'l_shaped'
      Architecture.require_mutable!(root)
      changes = request['changes']
      invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      Primitives.check_keys!(changes, INPUT_KEYS - %w[wall wall_id])
      input = editable_input(current)
      proposed = plan(model, input.merge(changes), exclude_id: Metadata.read(root)['homecad_id'], preserve_legacy: !changes.key?('modules'))
      constraint!('updated run has conflicts') unless proposed['conflicts'].empty?
      values = proposed['params']
      wall, = Architecture.wall_entity!(model, { 'homecad_id' => values['wall_id'] })
      Architecture.require_mutable!(wall)
      revision = Metadata.read(root)['revision']
      return MutationResult.success(operation: 'update_kitchen_run', updated: [serialize(root)], revision: revision) if
        KitchenData.canonical(editable_input(current)) == KitchenData.canonical(editable_input(values))

      previous_children = child_serializations(root)
      assign_semantic_objects!(values, current)
      rebuild = current['semantic_objects'] != values['semantic_objects'] ||
        KitchenData.canonical(editable_input(current).reject { |key, _| key == 'name' }) !=
        KitchenData.canonical(editable_input(values).reject { |key, _| key == 'name' })

      Operation.run('Update kitchen run', model: model) do
        KitchenData.write(root, values)
        root.name = values['name']
        if rebuild
          root.transformation = run_transform(model, values)
          build_geometry!(model, root, values, proposed)
        end
        Metadata.increment_revision!(root)
        children = rebuild ? child_serializations(root) : []
        previous_ids = previous_children.map { |child| child['homecad_id'] }
        current_ids = children.map { |child| child['homecad_id'] }
        MutationResult.success(operation: 'update_kitchen_run',
          created: children.reject { |child| previous_ids.include?(child['homecad_id']) },
          updated: [serialize(root)] + children.select { |child| previous_ids.include?(child['homecad_id']) },
          deleted: rebuild ? previous_children.reject { |child| current_ids.include?(child['homecad_id']) } : [],
          warnings: proposed['warnings'], revision: Metadata.read(root)['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "update_kitchen_run failed: #{error.message}")
    end

    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target])
      root, = resolve_run(model, request['target'])
      Architecture.require_mutable!(root)
      tombstones = [serialize(root)] + child_serializations(root)
      revision = Metadata.read(root)['revision']
      Operation.run('Delete kitchen run', model: model) do
        model.entities.erase_entities(root)
        MutationResult.success(operation: 'delete_kitchen_run', deleted: tombstones, revision: revision)
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

    def self.child_serializations(root)
      root.entities.to_a.filter_map do |child|
        next unless Metadata.read(child)['homecad_id']

        entry = Scene::Entry.new(entity: child, parent: root,
          path: [Scene.id(root), Scene.id(child)], transform: root.transformation)
        Serializer.serialize(entry, level: 'detailed')
      end
    end

    def self.number(value, label) = Geometry.finite_number(value, label)
    def self.editable_input(values)
      values.reject { |key, _| %w[tier span_mm top_mm run_start_mm semantic_objects].include?(key) }
    end
    def self.invalid!(message) = Primitives.invalid!(message)
    def self.constraint!(message) = Architecture.constraint!(message)
  end
end
