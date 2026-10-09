module HomeCAD
  module ElectricalSystem
    def self.dispatch(model, method, params)
      case method
      when 'create_distribution_panel' then ElectricalPanels.create(model,params)
      when 'get_distribution_panel' then ElectricalPanels.get(model,params)
      when 'update_distribution_panel' then ElectricalPanels.update(model,params)
      when 'delete_distribution_panel' then ElectricalPanels.delete(model,params)
      when 'assign_circuit_to_panel' then ElectricalPanels.assign(model,params)
      when 'create_consumer' then ElectricalConsumers.create(model,params)
      when 'get_consumer' then ElectricalConsumers.get(model,params)
      when 'list_consumers' then ElectricalConsumers.list(model,params)
      when 'update_consumer' then ElectricalConsumers.update(model,params)
      when 'delete_consumer' then ElectricalConsumers.delete(model,params)
      when 'connect_consumer' then ElectricalConsumers.connect(model,params)
      when 'find_unpowered_consumers' then ElectricalConsumers.unpowered(model,params)
      when 'get_circuit_load' then ElectricalConsumers.load(model,params)
      when 'create_cable_route' then ElectricalRoutes.create(model,params)
      when 'get_cable_route' then ElectricalRoutes.get(model,params)
      when 'list_cable_routes' then ElectricalRoutes.list(model,params)
      when 'update_cable_route' then ElectricalRoutes.update(model,params)
      when 'delete_cable_route' then ElectricalRoutes.delete(model,params)
      else raise Runtime::BridgeError.new(-32601,'unsupported_operation','unknown Electrical system method')
      end
    rescue Runtime::BridgeError then raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009,'geometry_error',"#{method} failed: #{error.message}")
    end

    def self.after_mutation(model,result)
      return result unless result.is_a?(Hash) && result['status'] == 'success'
      deleted = result.fetch('deleted',[])
      already = result.fetch('updated',[]).select { |r| r['homecad_type'] == 'electrical.circuit' }.map { |r| r['homecad_id'] }
      panels = deleted.select { |r| r['homecad_type'] == 'electrical.panel' }.map { |r| r['homecad_id'] }
      changed_circuits = ElectricalPanels.detach(model,panels,already_bumped: already) if panels.any?
      changed_circuits ||= []
      already |= changed_circuits.map { |r| r['homecad_id'] }
      all = ElectricalConsumers.records(model)
      orphaned = all.select do |r|
        begin
          ElectricalConsumers.source(model,r['parameters']['source_object_id']); false
        rescue Runtime::BridgeError => error
          raise unless %w[target_not_found constraint_violation].include?(error.category)
          true
        end
      end
      if orphaned.any?
        ids = orphaned.map { |r| ElectricalConsumers.circuit_id(model,r['parameters'],deleted: deleted) }
        changed_circuits.concat(Circuits.bump(model,ids.compact.uniq - already))
        ElectricalConsumers.write(model, all - orphaned)
        result['deleted'] = deleted + orphaned.map { |r| Circuits.serialize(r) }
        result['warnings'] = result.fetch('warnings',[]) + ["cascaded #{orphaned.length} Consumers whose appliance sources disappeared or changed type"]
      end
      if changed_circuits.any?
        replacement_ids = changed_circuits.map { |r| r['homecad_id'] }
        result['updated'] = result.fetch('updated',[]).reject { |r| replacement_ids.include?(r['homecad_id']) } + changed_circuits
      end
      result
    end
  end
  DomainHooks.register(:electrical_system) { |model,result| ElectricalSystem.after_mutation(model,result) }
end
