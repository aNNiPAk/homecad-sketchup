module HomeCAD
  module ElectricalPanels
    def self.panels(model)
      model.entities.to_a.select { |e| e.is_a?(Sketchup::Group) && e.valid? && Metadata.read(e)['type'] == 'electrical.panel' }
    end

    def self.resolve(model, target, mutable: false)
      entry = Targeting.resolve_one(model, target); entity = entry.entity
      Architecture.constraint!('target must be a root electrical.panel') unless entry.parent.nil? && panels(model).include?(entity)
      Architecture.require_mutable!(entity) if mutable
      entity
    end

    def self.circuits(model, id)
      ElectricalData.circuits(model).select { |record| record['parameters']['panel_id'] == id }
    end

    def self.create(model, request)
      params = Electrical.validate(model, request)
      Operation.run('Create distribution panel', model: model) do
        group = model.entities.add_group; group.name = params['name']
        Metadata.create!(group, type: 'electrical.panel')
        ElectricalData.write(group, params); group.transformation = Electrical.transform(model, params)
        Electrical.build(group, params)
        MutationResult.success(operation: 'create_distribution_panel', created: [Furniture.serialize_entity(group)], revision: 1)
      end
    end

    def self.get(model, request)
      Primitives.check_keys!(request, %w[target])
      panel = resolve(model, request['target'])
      Furniture.serialize_entity(panel).merge('circuit_ids' => circuits(model, Metadata.read(panel)['homecad_id']).map { |r| r['homecad_id'] })
    end

    def self.update(model, request)
      Primitives.check_keys!(request, %w[target changes])
      entity = resolve(model, request['target'], mutable: true); current = ElectricalData.read(entity)
      Primitives.invalid!('changes must be a nonempty object') unless request['changes'].is_a?(Hash) && !request['changes'].empty?
      proposed = Electrical.validate(model, request['changes'], current)
      return MutationResult.success(operation: 'update_distribution_panel', updated: [Furniture.serialize_entity(entity)], revision: Metadata.read(entity)['revision']) if proposed == current
      Operation.run('Update distribution panel', model: model) do
        ElectricalData.write(entity, proposed); entity.name = proposed['name']; entity.transformation = Electrical.transform(model, proposed)
        Electrical.build(entity, proposed) if current['dimensions_mm'] != proposed['dimensions_mm']
        Metadata.increment_revision!(entity)
        MutationResult.success(operation: 'update_distribution_panel', updated: [Furniture.serialize_entity(entity)], revision: Metadata.read(entity)['revision'])
      end
    end

    def self.detach(model, ids, already_bumped: [])
      records = ElectricalData.circuits(model)
      affected = records.select { |r| ids.include?(r['parameters']['panel_id']) }
      affected.each do |r|
        r['parameters']['panel_id'] = nil
        r['revision'] += 1 unless already_bumped.include?(r['homecad_id'])
      end
      ElectricalData.write_circuits(model, records) if affected.any?
      affected.map { |r| Circuits.serialize(r) }
    end

    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target detach_circuits])
      entity = resolve(model, request['target'], mutable: true)
      detach = request.fetch('detach_circuits', false)
      Primitives.invalid!('detach_circuits must be boolean') unless [true,false].include?(detach)
      id = Metadata.read(entity)['homecad_id']
      Architecture.constraint!('panel has circuits; set detach_circuits=true') if circuits(model, id).any? && !detach
      tombstone = Furniture.serialize_entity(entity)
      Operation.run('Delete distribution panel', model: model) do
        updated = self.detach(model, [id]); entity.erase!
        MutationResult.success(operation: 'delete_distribution_panel', deleted: [tombstone], updated: updated, revision: tombstone['metadata']['revision'])
      end
    end

    def self.assign(model, request)
      Primitives.check_keys!(request, %w[target panel_id])
      Primitives.invalid!('panel_id is required (null detaches)') unless request.key?('panel_id')
      Circuits.update(model, 'target' => request['target'], 'changes' => { 'panel_id' => request['panel_id'] }, operation: 'assign_circuit_to_panel')
    end
  end
end
