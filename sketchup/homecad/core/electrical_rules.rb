module HomeCAD
  # Named data-independent rulesets. No executable expressions or numeric national rules.
  module ElectricalRules
    RULESETS = { 'generic' => :generic }.freeze
    def self.describe(request)
      Primitives.check_keys!(request, %w[ruleset])
      name = request.fetch('ruleset', 'generic')
      raise Runtime::BridgeError.new(-32601, 'unsupported_operation', 'only generic Electrical ruleset is available') unless RULESETS.key?(name)
      { 'ruleset' => name, 'version' => 1, 'available_rulesets' => RULESETS.keys,
        'checks' => %w[consumer_unpowered voltage_mismatch orphan_reference missing_panel invalid_route_circuit missing_support collision],
        'constraints' => { 'require_panel' => 'optional boolean' },
        'limitations' => ['HomeCAD concept volumes only', 'No national regulations or automatic protective-device sizing'],
        'severity' => 'warning' }
    end
    def self.finding(category, **fields)
      { 'category' => category, 'severity' => 'warning' }.merge(fields.transform_keys(&:to_s))
    end

    def self.generic(model, constraints = {})
      Primitives.check_keys!(constraints, %w[require_panel])
      if constraints.key?('require_panel') && ![true,false].include?(constraints['require_panel'])
        Primitives.invalid!('constraints.require_panel must be boolean')
      end
      findings = []
      records = ElectricalData.circuits(model)
      ElectricalConsumers.records(model).each do |consumer|
        p = consumer['parameters']; id = consumer['homecad_id']
        begin
          ElectricalConsumers.source(model,p['source_object_id'])
        rescue Runtime::BridgeError => error
          raise unless %w[target_not_found constraint_violation ambiguous_target].include?(error.category)
          findings << finding('orphan_reference', consumer_id: id, reference_id: p['source_object_id'], relationship: 'source_object_id')
        end
        status = ElectricalConsumers.unpowered_status(model,p)
        findings << finding('consumer_unpowered', consumer_id: id, status: status, point_id: p['point_id']) if status
        if status == 'point_missing'
          findings << finding('orphan_reference', consumer_id: id, reference_id: p['point_id'], relationship: 'point_id')
        end
        cid = ElectricalConsumers.circuit_id(model,p)
        circuit = records.find { |r| r['homecad_id'] == cid }
        if p['voltage_v'] && circuit&.dig('parameters','voltage_v') && (p['voltage_v']-circuit['parameters']['voltage_v']).abs > 0.01
          findings << finding('voltage_mismatch', consumer_id: id, circuit_id: cid,
            consumer_voltage_v: p['voltage_v'], circuit_voltage_v: circuit['parameters']['voltage_v'])
        end
      end
      records.each do |circuit|
        p = circuit['parameters']; id = circuit['homecad_id']; panel_id = p['panel_id']
        if panel_id
          begin
            ElectricalPanels.resolve(model, { 'homecad_id' => panel_id })
          rescue Runtime::BridgeError => error
            raise unless %w[target_not_found constraint_violation].include?(error.category)
            findings << finding('orphan_reference', circuit_id: id, reference_id: panel_id, relationship: 'panel_id')
          end
        elsif p['require_panel'] == true || constraints['require_panel'] == true
          findings << finding('missing_panel', circuit_id: id)
        end
      end
      ElectricalRoutes.routes(model).each do |route|
        id = Metadata.read(route)['homecad_id']; cid = ElectricalRoutes.read(route)['circuit_id']
        unless cid && records.any? { |r| r['homecad_id'] == cid }
          findings << finding('invalid_route_circuit', route_id: id, circuit_id: cid)
        end
      end
      findings
    end

    def self.validate(model, request)
      Primitives.check_keys!(request, %w[target limit offset ruleset constraints])
      ruleset = request.fetch('ruleset','generic')
      raise Runtime::BridgeError.new(-32601,'unsupported_operation','only generic Electrical ruleset is available') unless RULESETS.key?(ruleset)
      constraints = request.fetch('constraints',{})
      Primitives.invalid!('constraints must be an object') unless constraints.is_a?(Hash)
      limit, offset = Circuits.page(request)
      target = request['target']; id = nil; selected = Electrical.points(model) + ElectricalPanels.panels(model)
      if target
        if target.is_a?(Hash) && target.keys == ['homecad_id'] &&
           (ElectricalData.circuits(model)+ElectricalConsumers.records(model)).any? { |r| r['homecad_id'] == target['homecad_id'] }
          id = Targeting.resolve_record(ElectricalData.circuits(model)+ElectricalConsumers.records(model),target)['homecad_id']
          selected = []
        else
          entry = Targeting.resolve_one(model,target)
          Architecture.constraint!('validate target must be an Electrical object') unless Metadata.read(entry.entity)['type'].to_s.start_with?('electrical.')
          id = Metadata.read(entry.entity)['homecad_id']
          selected = selected.select { |point| point.equal?(entry.entity) }
        end
      end
      entries = Electrical.findings(model,selected) + generic(model,constraints)
      entries.select! { |entry| %w[point_id consumer_id circuit_id route_id panel_id obstacle_id reference_id].any? { |key| entry[key] == id } } if id
      { 'findings' => entries.slice(offset,limit)||[], 'total'=>entries.length,
        'limit'=>limit,'offset'=>offset,'has_more'=>offset+limit < entries.length }
    end
  end
end
