module HomeCAD
  module ElectricalRoutes
    KEYS = %w[name circuit_id path_mm description].freeze
    def self.routes(model)
      model.entities.to_a.select { |e| e.is_a?(Sketchup::Group) && e.valid? && Metadata.read(e)['type'] == 'electrical.cable_route' }
    end
    def self.resolve(model, target, mutable: false)
      entry = Targeting.resolve_one(model, target); entity = entry.entity
      Architecture.constraint!('target must be a root electrical.cable_route') unless entry.parent.nil? && routes(model).include?(entity)
      Architecture.require_mutable!(entity) if mutable
      entity
    end
    def self.validate(model, request, defaults = {})
      Primitives.check_keys!(request, KEYS); params = { 'description' => nil }.merge(defaults).merge(request)
      Circuits.validate(params.slice('name', 'description'))
      Primitives.invalid!('circuit_id is required (null explicitly detaches)') unless params.key?('circuit_id')
      Primitives.invalid!('circuit_id must be null or a HomeCAD UUID') unless params['circuit_id'].nil? || Metadata.uuid?(params['circuit_id'])
      Circuits.resolve(model, { 'homecad_id' => params['circuit_id'] }) if params['circuit_id']
      path = params['path_mm']
      Primitives.invalid!('path_mm must contain 2..128 points') unless path.is_a?(Array) && (2..128).cover?(path.length)
      path.each { |p| Geometry.point_mm(p, 'path_mm[]') }
      params['path_mm'] = path.map { |p| p.map(&:to_f) }
      Primitives.invalid!('route length must be finite') unless length(params).finite?
      Architecture.constraint!('adjacent route points must be distinct by more than 0.01 mm') if params['path_mm'].each_cons(2).any? { |a,b| distance(a,b) <= 0.01 }
      params
    end
    def self.distance(a,b) = Math.sqrt(a.zip(b).sum { |x,y| (x-y)**2 })
    def self.length(params) = params['path_mm'].each_cons(2).sum { |a,b| distance(a,b) }
    def self.read(entity) = ElectricalData.read(entity)
    def self.write(entity, params)
      entity.set_attribute(Metadata::DICTIONARY, ElectricalData::PARAMS_KEY, JSON.generate(params))
      entity.set_attribute(Metadata::DICTIONARY, 'circuit_id', params['circuit_id'])
    end
    def self.serialize(entity)
      Furniture.serialize_entity(entity).merge('length_mm' => length(read(entity)))
    end
    def self.build(entity, params)
      entity.entities.clear!
      params['path_mm'].each_cons(2) do |a,b|
        edge = entity.entities.add_line(Geometry.point_mm(a,'route'), Geometry.point_mm(b,'route'))
        Primitives.geometry_created!(edge, 'SketchUp could not create route segment')
      end
    end
    def self.members(model, circuit_id) = routes(model).select { |e| read(e)['circuit_id'] == circuit_id }
    def self.create(model, request)
      params = validate(model, request)
      Operation.run('Create cable route', model: model) do
        root = model.entities.add_group; root.name = params['name']
        Metadata.create!(root, type: 'electrical.cable_route'); write(root, params); build(root, params)
        MutationResult.success(operation: 'create_cable_route', created: [serialize(root)],
          updated: Circuits.bump(model, [params['circuit_id']]), revision: 1)
      end
    end
    def self.get(model, request)
      Primitives.check_keys!(request, %w[target]); serialize(resolve(model, request['target']))
    end
    def self.list(model, request)
      Primitives.check_keys!(request, %w[limit offset]); limit, offset = Circuits.page(request); entries = routes(model)
      { 'routes' => (entries.slice(offset,limit)||[]).map { |e| serialize(e) }, 'total' => entries.length,
        'limit' => limit, 'offset' => offset, 'has_more' => offset+limit < entries.length }
    end
    def self.update(model, request)
      Primitives.check_keys!(request, %w[target changes]); entity = resolve(model, request['target'], mutable: true)
      current = read(entity); changes = request['changes']
      Primitives.invalid!('changes must be a nonempty object') unless changes.is_a?(Hash) && !changes.empty?
      params = validate(model, changes, current)
      return MutationResult.success(operation: 'update_cable_route', updated: [serialize(entity)], revision: Metadata.read(entity)['revision']) if params == current
      Operation.run('Update cable route', model: model) do
        write(entity, params); entity.name = params['name']; build(entity,params) if current['path_mm'] != params['path_mm']
        Metadata.increment_revision!(entity)
        MutationResult.success(operation: 'update_cable_route', updated: [serialize(entity)] + Circuits.bump(model, [current['circuit_id'],params['circuit_id']]), revision: Metadata.read(entity)['revision'])
      end
    end
    def self.delete(model, request)
      Primitives.check_keys!(request, %w[target]); entity = resolve(model,request['target'],mutable: true)
      tombstone = serialize(entity); id = read(entity)['circuit_id']
      Operation.run('Delete cable route',model: model) do
        entity.erase!
        MutationResult.success(operation: 'delete_cable_route',deleted: [tombstone],updated: Circuits.bump(model,[id]),revision: tombstone['metadata']['revision'])
      end
    end
    def self.detach(entity)
      write(entity, read(entity).merge('circuit_id'=>nil)); Metadata.increment_revision!(entity)
      serialize(entity)
    end
  end
end
