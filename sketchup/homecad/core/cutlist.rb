module HomeCAD
  module Cutlist
    MAX_LIMIT = 100

    def self.generate(model, request)
      Primitives.check_keys!(request, %w[target limit offset])
      entry = Targeting.resolve_one(model, request['target'])
      entity = entry.entity
      type = Metadata.read(entity)['type']
      unless entry.parent.nil? && %w[furniture.cabinet kitchen.run].include?(type)
        raise Runtime::BridgeError.new(-32008, 'constraint_violation',
          'cutlist target must be a root Cabinet or KitchenRun')
      end
      limit = request.fetch('limit', 50)
      offset = request.fetch('offset', 0)
      unless limit.is_a?(Integer) && (1..MAX_LIMIT).cover?(limit) &&
             offset.is_a?(Integer) && offset >= 0
        raise Runtime::BridgeError.new(-32602, 'invalid_request',
          "limit must be 1..#{MAX_LIMIT} and offset must be nonnegative")
      end
      records, warnings = if type == 'furniture.cabinet'
        params = FurnitureData.read_params(entity)
        drawer_warnings = params.fetch('drawers', []).empty? ? [] : [
          'drawer slide SKU and side clearance are project-selected; mounting and compatibility are unverified'
        ]
        [records_for(params, Metadata.read(entity)['homecad_id'], type), drawer_warnings]
      else
        kitchen_records(model, KitchenData.read(entity))
      end
      { 'target' => Serializer.serialize(entry, level: 'summary')['identity'],
        'records' => records.slice(offset, limit) || [], 'total' => records.length,
        'limit' => limit, 'offset' => offset, 'has_more' => offset + limit < records.length,
        'warnings' => warnings, 'units' => 'mm' }
    end

    def self.records_for(params, object_id, type, prefix: nil)
      parts = Furniture.part_schedule(params).map do |part|
        { 'record_kind' => 'panel', 'source_object_id' => object_id,
          'source_type' => type, 'part_key' => [prefix, part['part_key']].compact.join('/'),
          'part_kind' => part['part_kind'], 'quantity' => part['quantity'],
          'length_mm' => part['length_mm'], 'width_mm' => part['width_mm'],
          'thickness_mm' => part['thickness_mm'], 'material_id' => part['material_id'],
          'grain_axis' => part['grain_axis'], 'edge_band' => part['edge_band'],
          'sku' => part['sku'] }
      end
      hardware = params.fetch('manufacturing', {}).fetch('hardware', []).map do |item|
        { 'record_kind' => 'hardware', 'source_object_id' => object_id,
          'source_type' => type, 'part_key' => [prefix, "hardware:#{item['key']}"].compact.join('/'),
          'part_kind' => 'hardware', 'quantity' => item['quantity'],
          'length_mm' => nil, 'width_mm' => nil, 'thickness_mm' => nil,
          'material_id' => nil, 'grain_axis' => nil, 'edge_band' => nil,
          'sku' => item['sku'] }
      end
      parts + hardware + DrawerHardware.hardware_records(params, object_id, type, prefix: prefix)
    end

    def self.kitchen_records(model, run)
      records = []
      warnings = []
      modules = if run['layout_type'] == 'l_shaped'
        run['legs'].flat_map { |leg| leg['modules'].map { |item| [leg['key'], item] } }
      else
        run['modules'].map { |item| [nil, item] }
      end
      modules.each do |leg_key, item|
        if Kitchen::APPLIANCE_TYPES.include?(item['type'])
          warnings << "module #{item['key']} is a concept appliance; no manufacturing parts inferred"
          next
        end
        if %w[sink base_drawers].include?(item['type'])
          warnings << "module #{item['key']} has concept-only internal details; schedule covers the generic carcass"
        end
        params = Furniture.validate_params!(model, {
          'width_mm' => item['width_mm'], 'depth_mm' => item['depth_mm'],
          'height_mm' => item['height_mm'], 'detail_level' => 'construction',
          'material_id' => item['material_id'], 'front_material_id' => item['front_material_id'],
          'manufacturing' => item.fetch('manufacturing', {})
        })
        key = [leg_key && "leg:#{leg_key}", "module:#{item['key']}"].compact.join('/')
        object_id = run.fetch('semantic_objects', {}).fetch(key, {})['homecad_id']
        records.concat(records_for(params, object_id, 'kitchen.module', prefix: key))
      end
      if run['layout_type'] == 'l_shaped' && run['corner']['mode'] == 'blind_cabinet'
        corner = run['corner']
        first, second = run['legs']
        accessed = corner['access_leg'] == first['key'] ? first : second
        other = corner['access_leg'] == first['key'] ? second : first
        other_wall = Architecture.wall_entity!(model, { 'homecad_id' => other['wall_id'] })[1]
        width = corner['access_leg'] == first['key'] ? corner['span_first_mm'] : corner['span_second_mm']
        width -= other_wall['thickness_mm'] / 2.0
        depth = accessed['modules'].first['depth_mm']
        cabinet = Furniture.validate_params!(model, {
          'width_mm' => width, 'depth_mm' => depth, 'height_mm' => run['height_mm'],
          'detail_level' => 'construction' })
        object_id = run.fetch('semantic_objects', {}).fetch('corner', {})['homecad_id']
        records.concat(records_for(cabinet, object_id, 'kitchen.corner_cabinet', prefix: 'corner'))
        warnings << 'blind corner join is a concept carcass; verify access and panel takeoff before fabrication'
      end
      if run['layout_type'] == 'l_shaped'
        if run.dig('countertop', 'enabled')
          shape = KitchenVariants.footprint(model, run)
          top = run['countertop']
          records << { 'record_kind' => 'shaped_panel',
            'source_object_id' => run.fetch('semantic_objects', {}).fetch('countertop', {})['homecad_id'],
            'source_type' => 'kitchen.countertop', 'part_key' => 'countertop',
            'part_kind' => 'countertop', 'quantity' => 1,
            'length_mm' => shape['arm_lengths_mm'][0],
            'width_mm' => shape['arm_lengths_mm'][1],
            'thickness_mm' => top['thickness_mm'], 'material_id' => top['material_id'],
            'grain_axis' => nil, 'edge_band' => nil, 'sku' => nil,
            'profile_points_mm' => shape['polygon_mm'],
            'cutouts_mm' => top['cutouts'], 'manufacturing_status' => 'concept_shaped' }
          warnings << 'L-shaped countertop profile and cutouts are conceptual; verify fabrication dimensions'
        end
        run.fetch('panels', {}).each do |key, panel|
          leg = run['legs'][key == 'first' ? 0 : 1]
          records << { 'record_kind' => 'panel',
            'source_object_id' => run.fetch('semantic_objects', {}).fetch("panel:#{key}", {})['homecad_id'],
            'source_type' => 'kitchen.end_panel', 'part_key' => "panel:#{key}",
            'part_kind' => 'end_panel', 'quantity' => 1,
            'length_mm' => run['height_mm'],
            'width_mm' => leg['modules'].map { |item| item['depth_mm'] }.max,
            'thickness_mm' => panel['thickness_mm'],
            'material_id' => panel['material_id'], 'grain_axis' => panel['grain_axis'],
            'edge_band' => panel['edge_band'], 'sku' => panel['sku'] }
        end
      end
      [records, warnings]
    end
  end
end
