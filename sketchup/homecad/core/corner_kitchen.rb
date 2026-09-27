require 'digest'
require 'securerandom'

module HomeCAD
  module CornerKitchen
    CONNECT_TOLERANCE_MM = 1.0
    RIGHT_ANGLE_TOLERANCE_DEGREES = 0.1
    LEG_KEYS = %w[key wall wall_id start_mm end_mm side modules clearance_mm
                  start_clearance_mm end_clearance_mm filler_max_mm constraints].freeze
    CORNER_KEYS = %w[mode span_first_mm span_second_mm access_leg].freeze

    def self.plan(model, input, exclude_id: nil, overrides: {})
      Primitives.check_keys!(input, %w[layout_type legs corner name countertop panels])
      legs = input['legs']
      invalid!('legs must contain exactly two ordered wall legs') unless legs.is_a?(Array) && legs.length == 2
      invalid!('leg keys must be distinct') unless legs.map { |leg| leg.is_a?(Hash) && leg['key'] }.uniq.length == 2
      total_modules = legs.sum { |leg| leg.is_a?(Hash) && leg['modules'].is_a?(Array) ? leg['modules'].length : 0 }
      invalid!('L-shaped run supports at most 32 modules across both legs') if total_modules > Kitchen::MAX_MODULES
      info = legs.map.with_index do |leg, index|
        invalid!("legs[#{index}] must be an object") unless leg.is_a?(Hash)
        Primitives.check_keys!(leg, LEG_KEYS)
        key = leg['key']
        invalid!('leg key must be a nonempty string up to 64 characters') unless
          key.is_a?(String) && !key.empty? && key.length <= 64
        wall, stored, data = Architecture.wall_entity!(model,
          leg['wall'] || { 'homecad_id' => leg['wall_id'] })
        wall_id = data['homecad_id']
        wall_params = overrides.fetch(wall_id, stored)
        frame, normalized_wall = Architecture.validate_wall_params!(wall_params)
        { 'key' => key, 'wall_id' => wall_id, 'wall' => normalized_wall,
          'frame' => frame, 'wall_revision' => data['revision'], 'input' => leg }
      end
      invalid!('corner legs must reference distinct Walls') if info[0]['wall_id'] == info[1]['wall_id']
      end_pairs = [[0, 0], [0, 1], [1, 0], [1, 1]]
      matches = end_pairs.select do |a, b|
        distance(endpoint(info[0]['wall'], a), endpoint(info[1]['wall'], b)) <= CONNECT_TOLERANCE_MM
      end
      constraint!('wall baselines must meet at one endpoint within 1 mm') unless matches.length == 1
      a_end, b_end = matches.first
      origin = endpoint(info[0]['wall'], a_end)
      directions = [info[0]['frame'].u_axis, info[1]['frame'].u_axis]
      directions[0] = directions[0].map { |value| -value } if a_end == 1
      directions[1] = directions[1].map { |value| -value } if b_end == 1
      dot = directions[0].zip(directions[1]).sum { |a, b| a * b }
      tolerance = Math.sin(RIGHT_ANGLE_TOLERANCE_DEGREES * Math::PI / 180.0)
      constraint!('corner Walls must meet at 90 degrees ±0.1 degrees') if dot.abs > tolerance
      cross = directions[0][0] * directions[1][1] - directions[0][1] * directions[1][0]
      constraint!('legs must be ordered counterclockwise around the corner interior') unless cross > 0
      info.each_with_index do |item, index|
        side = item['input']['side']
        invalid!('leg side must be positive_v or negative_v') unless WallAttachment::SIDES.include?(side)
        side_axis = item['frame'].v_axis.map { |value| side == 'positive_v' ? value : -value }
        other = directions[1 - index]
        inward = side_axis.zip(other).sum { |a, b| a * b }
        constraint!('both Kitchen sides must face the corner interior') if inward < 1 - tolerance
      end
      corner = input['corner']
      invalid!('corner must be an object') unless corner.is_a?(Hash)
      Primitives.check_keys!(corner, CORNER_KEYS)
      mode = corner['mode']
      invalid!('corner.mode must be void or blind_cabinet') unless %w[void blind_cabinet].include?(mode)
      spans = %w[span_first_mm span_second_mm].map do |key|
        Geometry.positive_length(corner[key], "corner.#{key}")
      end
      access = corner['access_leg']
      if mode == 'blind_cabinet'
        invalid!('corner.access_leg must identify one leg') unless info.map { |item| item['key'] }.include?(access)
      elsif access
        invalid!('void corner cannot have access_leg')
      end
      normalized_corner = { 'mode' => mode, 'span_first_mm' => spans[0],
        'span_second_mm' => spans[1] }
      normalized_corner['access_leg'] = access if access
      name = input.fetch('name', 'L-shaped kitchen run')
      invalid!('name must be a nonempty string up to 128 characters') unless
        name.is_a?(String) && !name.strip.empty? && name.length <= 128

      plans = info.map.with_index do |item, index|
        leg = item['input']
        start = Geometry.finite_number(leg['start_mm'], "legs[#{index}].start_mm")
        finish = Geometry.finite_number(leg['end_mm'], "legs[#{index}].end_mm")
        at_start = [a_end, b_end][index] == 0
        constraint!('leg interval must touch its common Wall endpoint') unless
          (at_start ? start.abs : (finish - item['frame'].length_mm).abs) <= CONNECT_TOLERANCE_MM
        if at_start
          start += spans[index]
        else
          finish -= spans[index]
        end
        constraint!('leg interval exceeds proposed Wall length') if
          start < -Kitchen::TOLERANCE_MM || finish > item['frame'].length_mm + Kitchen::TOLERANCE_MM
        constraint!('corner span leaves no room for modules') unless finish > start + Kitchen::TOLERANCE_MM
        request = leg.slice(*(LEG_KEYS - %w[key wall wall_id start_mm end_mm]))
        request.merge!('wall_id' => item['wall_id'], 'start_mm' => start, 'end_mm' => finish,
                       'countertop' => false, 'plinth' => false)
        constraints = request.fetch('constraints', {}).merge('require_countertop' => false)
        request['constraints'] = constraints
        leg_plan = Kitchen.plan(model, request, exclude_id: exclude_id)
        constraint!('L-shaped KitchenRun supports base modules only') unless leg_plan.dig('params', 'tier') == 'base'
        constraint!('leg modules exceed proposed Wall height') if leg_plan.dig('params', 'top_mm') >
          item['wall']['height_mm'] + Kitchen::TOLERANCE_MM
        item.merge('corner_at_start' => at_start,
          'plan' => leg_plan, 'span' => spans[index], 'original_start' => leg['start_mm'],
          'original_end' => leg['end_mm'])
      end
      tops = plans.map { |item| item.dig('plan', 'params', 'modules', 0, 'bottom_mm') +
        item.dig('plan', 'params', 'modules', 0, 'height_mm') }
      constraint!('both legs must have equal cabinet top elevations') if (tops[0] - tops[1]).abs > Kitchen::TOLERANCE_MM
      depths = plans.map { |item| item.dig('plan', 'params', 'modules').map { |part| part['depth_mm'] }.max }
      constraint!('corner spans must cover the neighboring leg depth and wall half-thickness') if
        spans[0] < depths[1] + plans[1]['wall']['thickness_mm'] / 2.0 - Kitchen::TOLERANCE_MM ||
        spans[1] < depths[0] + plans[0]['wall']['thickness_mm'] / 2.0 - Kitchen::TOLERANCE_MM
      normalized_legs = plans.map do |item|
        values = item['plan']['params']
        { 'key' => item['key'], 'wall_id' => item['wall_id'],
          'start_mm' => item['original_start'], 'end_mm' => item['original_end'],
          'side' => values['side'], 'modules' => values['modules'],
          'clearance_mm' => values['clearance_mm'],
          'start_clearance_mm' => values['start_clearance_mm'],
          'end_clearance_mm' => values['end_clearance_mm'],
          'filler_max_mm' => values['filler_max_mm'],
          'constraints' => values['constraints'], 'positions' => item['plan']['positions'],
          'filler_mm' => item['plan']['filler_mm'],
          'corner_at_start' => item['corner_at_start'] }
      end
      params = { 'layout_type' => 'l_shaped', 'legs' => normalized_legs,
        'corner' => normalized_corner, 'corner_point_mm' => origin,
        'name' => name, 'bottom_mm' => plans[0].dig('plan', 'params', 'modules', 0, 'bottom_mm'),
        'height_mm' => plans[0].dig('plan', 'params', 'modules', 0, 'height_mm') }
      KitchenVariants.normalize!(model, params, input, overrides: overrides)
      conflicts = plans.flat_map do |item|
        item['plan']['conflicts'].map { |conflict| conflict.merge('leg_key' => item['key']) }
      end
      warnings = plans.flat_map { |item| item['plan']['warnings'].map { |warning| "#{item['key']}: #{warning}" } }
      _cross_zones, cross_findings, incomplete = cross_leg_service_findings(model, params)
      service_zones = plans.flat_map do |item|
        item['plan']['service_zones'].map { |zone| zone.merge('leg_key' => item['key']) }
      end
      service_findings = plans.flat_map do |item|
        item['plan']['service_findings'].map { |finding| finding.merge('leg_key' => item['key']) }
      end + cross_findings
      if service_findings.length > ServiceZones::MAX_FINDINGS
        service_findings = service_findings.first(ServiceZones::MAX_FINDINGS)
        incomplete = true
      end
      strict = normalized_legs.any? { |leg| leg['constraints']['require_service_clearance'] }
      if strict
        conflicts.concat(service_findings.map { |finding| finding.merge('message' =>
          "#{finding['leg_key']}/#{finding['module_key']} service zone is blocked") })
      elsif service_findings.any?
        warnings << "#{service_findings.length} cross-leg service clearance obstruction(s)"
      end
      conflicts << { 'code' => 'service_check_incomplete',
        'message' => 'corner service clearance check exceeded its result limit' } if incomplete
      result = { 'params' => params, 'leg_plans' => plans.map { |item| item['plan'] },
        'wall_revisions' => info.to_h { |item| [item['wall_id'], item['wall_revision']] },
        'conflicts' => conflicts, 'warnings' => warnings,
        'service_zones' => service_zones, 'service_findings' => service_findings,
        'units' => 'mm' }
      result['fingerprint'] = Digest::SHA256.hexdigest(JSON.generate(KitchenData.canonical(result)))
      result
    end

    def self.editable(params)
      panels = params.fetch('panels', {}).transform_values { |panel| panel.reject { |key, _| key == 'offset_mm' } }
      { 'layout_type' => 'l_shaped', 'name' => params['name'],
        'countertop' => params.fetch('countertop', { 'enabled' => false }),
        'panels' => panels,
        'corner' => params['corner'], 'legs' => params['legs'].map do |leg|
          leg.slice(*%w[key wall_id start_mm end_mm side modules clearance_mm
                       start_clearance_mm end_clearance_mm filler_max_mm constraints])
        end }
    end

    def self.descriptors(params)
      result = {}
      params['legs'].each do |leg|
        leg['positions'].each do |position|
          item = leg['modules'].find { |module_item| module_item['key'] == position['key'] }
          key = "leg:#{leg['key']}/module:#{item['key']}"
          kind = Kitchen::APPLIANCE_TYPES.include?(item['type']) ? 'kitchen.appliance' : 'kitchen.base_cabinet'
          result[key] = { 'type' => kind, 'params' => item.merge(
            'module_key' => "#{leg['key']}/#{item['key']}",
            'module_type' => item['type'], 'offset_mm' => position['offset_mm'],
            'wall_id' => leg['wall_id'], 'side' => leg['side']) }
        end
        if leg['filler_mm'].positive?
          key = "leg:#{leg['key']}/filler"
          result[key] = { 'type' => 'kitchen.filler', 'params' => {
            'wall_id' => leg['wall_id'], 'side' => leg['side'],
            'width_mm' => leg['filler_mm'], 'height_mm' => params['height_mm'] } }
        end
      end
      result['corner'] = { 'type' => params['corner']['mode'] == 'void' ?
        'kitchen.corner_void' : 'kitchen.corner_cabinet',
        'params' => params['corner'].merge('wall_ids' => params['legs'].map { |leg| leg['wall_id'] }) }
      if params.dig('countertop', 'enabled')
        result['countertop'] = { 'type' => 'kitchen.countertop', 'params' => params['countertop'] }
      end
      params.fetch('panels', {}).each do |key, panel|
        result["panel:#{key}"] = { 'type' => 'kitchen.end_panel', 'params' => panel }
      end
      result
    end

    def self.assign_semantic!(values, previous = nil, host_change: false)
      old_records = previous ? previous.fetch('semantic_objects', {}) : {}
      old_descriptors = previous ? descriptors(previous) : {}
      values['semantic_objects'] = descriptors(values).to_h do |key, descriptor|
        prior = old_records[key]
        if prior && Metadata.uuid?(prior['homecad_id'])
          changed = host_change || KitchenData.canonical(old_descriptors[key]) != KitchenData.canonical(descriptor)
          [key, { 'homecad_id' => prior['homecad_id'],
                  'revision' => prior['revision'] + (changed ? 1 : 0) }]
        else
          [key, { 'homecad_id' => SecureRandom.uuid, 'revision' => 1 }]
        end
      end
    end

    def self.apply(model, supplied)
      fresh = plan(model, editable(supplied['params']))
      constraint!('corner kitchen plan is stale or changed; plan again') unless fresh == supplied
      constraint!('corner kitchen plan has conflicts') unless fresh['conflicts'].empty?
      values = fresh['params']
      values['legs'].each do |leg|
        wall, = Architecture.wall_entity!(model, { 'homecad_id' => leg['wall_id'] })
        Architecture.require_mutable!(wall)
      end
      assign_semantic!(values)
      Operation.run('Apply corner kitchen run', model: model) do
        root = model.entities.add_group
        Primitives.geometry_created!(root, 'SketchUp could not create corner KitchenRun Group')
        root.name = values['name']
        Metadata.create!(root, type: 'kitchen.run')
        KitchenData.write(root, values)
        build_geometry!(model, root, values)
        MutationResult.success(operation: 'apply_kitchen_run',
          created: [Kitchen.serialize(root)] + Kitchen.child_serializations(root),
          warnings: fresh['warnings'], revision: 1)
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "corner apply failed: #{error.message}")
    end

    def self.validate(model, root, values)
      fresh = plan(model, editable(values), exclude_id: Metadata.read(root)['homecad_id'])
      { 'homecad_id' => Metadata.read(root)['homecad_id'],
        'layout_type' => 'l_shaped', 'valid' => fresh['conflicts'].empty?,
        'conflicts' => fresh['conflicts'], 'warnings' => fresh['warnings'],
        'service_zones' => fresh['service_zones'],
        'service_findings' => fresh['service_findings'],
        'module_count' => values['legs'].sum { |leg| leg['modules'].length }, 'units' => 'mm' }
    end

    def self.update(model, root, current, changes)
      Architecture.require_mutable!(root)
      invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      Primitives.check_keys!(changes, %w[legs corner name countertop panels])
      proposed = plan(model, editable(current).merge(changes),
        exclude_id: Metadata.read(root)['homecad_id'])
      constraint!('updated corner kitchen has conflicts') unless proposed['conflicts'].empty?
      values = proposed['params']
      revision = Metadata.read(root)['revision']
      return MutationResult.success(operation: 'update_kitchen_run',
        updated: [Kitchen.serialize(root)], revision: revision) if
          KitchenData.canonical(editable(current)) == KitchenData.canonical(editable(values))
      previous_children = Kitchen.child_serializations(root)
      assign_semantic!(values, current)
      Operation.run('Update corner kitchen run', model: model) do
        KitchenData.write(root, values)
        root.name = values['name']
        build_geometry!(model, root, values)
        Metadata.increment_revision!(root)
        children = Kitchen.child_serializations(root)
        prior_ids = previous_children.map { |item| item['homecad_id'] }
        current_ids = children.map { |item| item['homecad_id'] }
        MutationResult.success(operation: 'update_kitchen_run',
          created: children.reject { |item| prior_ids.include?(item['homecad_id']) },
          updated: [Kitchen.serialize(root)] + children.select { |item| prior_ids.include?(item['homecad_id']) },
          deleted: previous_children.reject { |item| current_ids.include?(item['homecad_id']) },
          warnings: proposed['warnings'], revision: Metadata.read(root)['revision'])
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "corner update failed: #{error.message}")
    end

    def self.preflight_host_update(model, root, overrides)
      current = KitchenData.read(root)
      proposal = plan(model, editable(current), exclude_id: Metadata.read(root)['homecad_id'],
        overrides: overrides)
      constraint!('Wall update would invalidate corner KitchenRun') unless proposal['conflicts'].empty?
      [root, current, proposal['params']]
    end

    def self.apply_host_update!(model, item)
      root, current, values = item
      assign_semantic!(values, current, host_change: true)
      KitchenData.write(root, values)
      build_geometry!(model, root, values)
    end

    def self.build_geometry!(model, root, values)
      root.entities.clear!
      run_id = Metadata.read(root)['homecad_id']
      all_descriptors = descriptors(values)
      values['legs'].each do |leg|
        wall, wall_params, = Architecture.wall_entity!(model, { 'homecad_id' => leg['wall_id'] })
        frame, normalized = Architecture.validate_wall_params!(wall_params)
        leg['positions'].each do |position|
          item = leg['modules'].find { |candidate| candidate['key'] == position['key'] }
          key = "leg:#{leg['key']}/module:#{item['key']}"
          group = root.entities.add_group
          group.name = key
          descriptor = all_descriptors.fetch(key)
          KitchenData.write_child(group, record: values['semantic_objects'].fetch(key),
            descriptor: descriptor, run_id: run_id, wall_id: leg['wall_id'])
          attachment = { 'wall_id' => leg['wall_id'], 'offset_mm' => position['offset_mm'],
            'bottom_mm' => item['bottom_mm'], 'side' => leg['side'],
            'clearance_mm' => leg['clearance_mm'], 'span_u_mm' => item['width_mm'],
            'span_z_mm' => item['height_mm'] }
          group.transformation = WallAttachment.wall_transform(frame, normalized['thickness_mm'],
            attachment, wall_height_mm: normalized['height_mm'])
          cabinet = Furniture.validate_params!(model, {
            'width_mm' => item['width_mm'], 'depth_mm' => item['depth_mm'],
            'height_mm' => item['height_mm'], 'detail_level' => 'concept' })
          Furniture.build_geometry!(group, cabinet)
        end
        next unless leg['filler_mm'].positive?

        key = "leg:#{leg['key']}/filler"
        last = leg['positions'].last
        offset = last['offset_mm'] + last['width_mm']
        group = root.entities.add_group
        group.name = key
        KitchenData.write_child(group, record: values['semantic_objects'].fetch(key),
          descriptor: all_descriptors.fetch(key), run_id: run_id, wall_id: leg['wall_id'])
        attachment = { 'wall_id' => leg['wall_id'], 'offset_mm' => offset,
          'bottom_mm' => values['bottom_mm'], 'side' => leg['side'],
          'clearance_mm' => leg['clearance_mm'], 'span_u_mm' => leg['filler_mm'],
          'span_z_mm' => values['height_mm'] }
        group.transformation = WallAttachment.wall_transform(frame, normalized['thickness_mm'],
          attachment, wall_height_mm: normalized['height_mm'])
        depth = leg['modules'].map { |item| item['depth_mm'] }.max
        Kitchen.box!(group, 'filler', 0, 0, 0, leg['filler_mm'], depth, values['height_mm'])
      end
      build_corner!(model, root, values, all_descriptors.fetch('corner'), run_id)
      if values.dig('countertop', 'enabled')
        KitchenVariants.build_countertop!(model, root, values, all_descriptors.fetch('countertop'), run_id)
      end
      values.fetch('panels', {}).each_key do |key|
        KitchenVariants.build_panel!(model, root, values, key,
          all_descriptors.fetch("panel:#{key}"), run_id)
      end
    end

    def self.build_corner!(model, root, values, descriptor, run_id)
      first, second = values['legs']
      frames = [first, second].map do |leg|
        Architecture.validate_wall_params!(Architecture.wall_entity!(model,
          { 'homecad_id' => leg['wall_id'] })[1])
      end
      directions = frames.each_with_index.map do |(frame, _wall), index|
        values['legs'][index]['corner_at_start'] ? frame.u_axis : frame.u_axis.map { |v| -v }
      end
      d1, d2 = directions
      half1 = frames[0][1]['thickness_mm'] / 2.0
      half2 = frames[1][1]['thickness_mm'] / 2.0
      origin = values['corner_point_mm'].each_index.map do |i|
        values['corner_point_mm'][i] + d1[i] * half2 + d2[i] * half1
      end
      group = root.entities.add_group
      group.name = 'corner'
      KitchenData.write_child(group, record: values['semantic_objects'].fetch('corner'),
        descriptor: descriptor, run_id: run_id, wall_id: first['wall_id'])
      corner = values['corner']
      span1 = corner['span_first_mm'] - half2
      span2 = corner['span_second_mm'] - half1
      if corner['mode'] == 'void'
        group.transformation = axes(origin, d1, d2)
        Kitchen.box!(group, 'front_panel_first', 0, span2 - 18, values['bottom_mm'],
          span1, 18, values['height_mm'])
        Kitchen.box!(group, 'front_panel_second', span1 - 18, 0, values['bottom_mm'],
          18, span2, values['height_mm'])
      else
        first_access = corner['access_leg'] == first['key']
        x_axis = first_access ? d1 : d2.map { |value| -value }
        y_axis = first_access ? d2 : d1
        width = first_access ? span1 : span2
        depth = first_access ? first['modules'].first['depth_mm'] : second['modules'].first['depth_mm']
        cabinet_origin = first_access ? origin : origin.each_index.map { |i| origin[i] + d2[i] * span2 }
        group.transformation = axes(cabinet_origin, x_axis, y_axis)
        cabinet = Furniture.validate_params!(model, {
          'width_mm' => width, 'depth_mm' => depth, 'height_mm' => values['height_mm'],
          'detail_level' => 'construction', 'fronts' => [{ 'key' => 'access',
            'kind' => 'door', 'x_mm' => 0, 'z_mm' => 0,
            'width_mm' => width, 'height_mm' => values['height_mm'] }] })
        Furniture.build_geometry!(group, cabinet)
      end
      group
    end

    def self.occupied_boxes(model, values)
      boxes = values['legs'].each_with_index.flat_map do |leg, index|
        wall = Architecture.wall_entity!(model, { 'homecad_id' => leg['wall_id'] })[1]
        frame = ServiceZones.frame_from_wall(wall, side: leg['side'])
        result = leg['positions'].map do |position|
          item = leg['modules'].find { |candidate| candidate['key'] == position['key'] }
          ["leg:#{leg['key']}/module:#{item['key']}", ServiceZones.box(*frame,
            [position['offset_mm'], position['offset_mm'] + item['width_mm'],
             leg['clearance_mm'], leg['clearance_mm'] + item['depth_mm'],
             item['bottom_mm'], item['bottom_mm'] + item['height_mm']])]
        end
        if leg['filler_mm'].positive?
          last = leg['positions'].last
          start = last['offset_mm'] + last['width_mm']
          depth = leg['modules'].map { |item| item['depth_mm'] }.max
          result << ["leg:#{leg['key']}/filler", ServiceZones.box(*frame,
            [start, start + leg['filler_mm'], leg['clearance_mm'], leg['clearance_mm'] + depth,
             values['bottom_mm'], values['bottom_mm'] + values['height_mm']])]
        end
        panel = values.fetch('panels', {})[index.zero? ? 'first' : 'second']
        if panel
          depth = leg['modules'].map { |item| item['depth_mm'] }.max
          result << ["panel:#{index.zero? ? 'first' : 'second'}", ServiceZones.box(*frame,
            [panel['offset_mm'], panel['offset_mm'] + panel['thickness_mm'],
             leg['clearance_mm'], leg['clearance_mm'] + depth,
             values['bottom_mm'], values['bottom_mm'] + values['height_mm']])]
        end
        result
      end
      first, second = values['legs']
      frames = [first, second].map do |leg|
        Architecture.validate_wall_params!(Architecture.wall_entity!(model,
          { 'homecad_id' => leg['wall_id'] })[1])
      end
      d1 = first['corner_at_start'] ? frames[0][0].u_axis : frames[0][0].u_axis.map { |v| -v }
      d2 = second['corner_at_start'] ? frames[1][0].u_axis : frames[1][0].u_axis.map { |v| -v }
      half1 = frames[0][1]['thickness_mm'] / 2.0
      half2 = frames[1][1]['thickness_mm'] / 2.0
      origin = values['corner_point_mm'].each_index.map do |i|
        values['corner_point_mm'][i] + d1[i] * half2 + d2[i] * half1
      end
      span1 = values['corner']['span_first_mm'] - half2
      span2 = values['corner']['span_second_mm'] - half1
      bottom = values['bottom_mm']; top = bottom + values['height_mm']
      if values['corner']['mode'] == 'void'
        boxes << ['corner:first_panel', ServiceZones.box(origin, d1, d2,
          [0, span1, span2 - 18, span2, bottom, top])]
        boxes << ['corner:second_panel', ServiceZones.box(origin, d1, d2,
          [span1 - 18, span1, 0, span2, bottom, top])]
      else
        first_access = values['corner']['access_leg'] == first['key']
        x = first_access ? d1 : d2.map { |v| -v }
        y = first_access ? d2 : d1
        width = first_access ? span1 : span2
        depth = first_access ? first['modules'].first['depth_mm'] : second['modules'].first['depth_mm']
        position = first_access ? origin : origin.each_index.map { |i| origin[i] + d2[i] * span2 }
        boxes << ['corner', ServiceZones.box(position, x, y, [0, width, 0, depth, bottom, top])]
      end
      boxes
    end

    def self.cross_leg_service_findings(model, params)
      occupied = occupied_boxes(model, params)
      zones = []
      findings = []
      incomplete = false
      params['legs'].each do |leg|
        wall = Architecture.wall_entity!(model, { 'homecad_id' => leg['wall_id'] })[1]
        frame = ServiceZones.frame_from_wall(wall, side: leg['side'])
        leg['positions'].each do |position|
          item = leg['modules'].find { |candidate| candidate['key'] == position['key'] }
          clearance = item['service_clearance_mm']
          next unless clearance

          body = [position['offset_mm'], position['offset_mm'] + item['width_mm'],
            leg['clearance_mm'], leg['clearance_mm'] + item['depth_mm'],
            item['bottom_mm'], item['bottom_mm'] + item['height_mm']]
          zones << { 'leg_key' => leg['key'], 'module_key' => item['key'],
            'clearance_mm' => clearance }
          ServiceZones.slabs(body, clearance).each do |direction, limits|
            zone = ServiceZones.box(*frame, limits)
            occupied.each do |key, obstacle|
              next if key.start_with?("leg:#{leg['key']}/")
              next unless ServiceZones.overlap?(zone, obstacle)

              finding = { 'code' => 'service_clearance_blocked', 'leg_key' => leg['key'],
                'module_key' => item['key'], 'direction' => direction,
                'object_id' => nil, 'object_type' => 'kitchen.corner_run',
                'obstacle_key' => key }
              next if findings.include?(finding)
              if findings.length >= ServiceZones::MAX_FINDINGS
                incomplete = true
                break
              end
              findings << finding
            end
            break if incomplete
          end
        end
      end
      [zones, findings, incomplete]
    end

    def self.axes(origin, x_axis, y_axis)
      Geom::Transformation.axes(Geometry.point_mm(origin, 'corner.origin_mm'),
        Geom::Vector3d.new(*x_axis), Geom::Vector3d.new(*y_axis), Geom::Vector3d.new(0, 0, 1))
    end

    def self.endpoint(wall, index)
      index == 0 ? wall['start_mm'] : wall['end_mm']
    end

    def self.distance(left, right)
      Math.sqrt(left.zip(right).sum { |a, b| (a - b)**2 })
    end

    def self.invalid!(message) = Primitives.invalid!(message)
    def self.constraint!(message) = Architecture.constraint!(message)
  end
end
