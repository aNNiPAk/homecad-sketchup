module HomeCAD
  module Scene
    MAX_VISITS = 10_000
    MAX_DEPTH = 32
    Entry = Struct.new(:entity, :parent, :path, :transform, keyword_init: true)

    def self.type(entity)
      entity.typename
    end

    def self.id(entity)
      entity.respond_to?(:persistent_id) ? entity.persistent_id : entity.entityID
    end

    def self.children(entity)
      return entity.entities if entity.respond_to?(:entities)
      return entity.definition.entities if entity.respond_to?(:definition) && entity.definition

      nil
    end

    def self.root(model)
      model.entities.map { |entity| Entry.new(entity: entity, parent: nil, path: [id(entity)], transform: nil) }
    end

    def self.collection(model, context: 'root', parent: nil)
      return root(model) if parent.nil? && context == 'root'
      if parent.nil? && context == 'active'
        return model.active_entities.map { |entity| Entry.new(entity: entity, parent: nil, path: [id(entity)], transform: nil) }
      end
      raise Runtime::BridgeError.new(-32602, 'invalid_request', 'invalid context') unless parent

      selected = Targeting.resolve_one(model, parent)
      children = children(selected.entity)
      raise Runtime::BridgeError.new(-32602, 'invalid_request', 'target has no children') unless children

      child_transform = compose(selected.transform, selected.entity)
      children.map do |entity|
        Entry.new(entity: entity, parent: selected.entity, path: selected.path + [id(entity)],
                  transform: child_transform)
      end
    end

    def self.walk(model)
      visits = 0
      stack = root(model).reverse.map { |entry| [entry, 0] }
      until stack.empty?
        entry, depth = stack.pop
        visits += 1
        if visits > MAX_VISITS || depth > MAX_DEPTH
          raise Runtime::BridgeError.new(-32004, 'constraint_violation', 'scene traversal budget exceeded; narrow the target')
        end
        yield entry
        children = children(entry.entity)
        next unless children

        transform = compose(entry.transform, entry.entity)
        children.reverse_each do |entity|
          stack << [Entry.new(entity: entity, parent: entry.entity,
                              path: entry.path + [id(entity)], transform: transform), depth + 1]
        end
      end
    end

    def self.compose(parent, entity)
      own = entity.respond_to?(:transformation) ? entity.transformation : nil
      return parent unless own
      return own unless parent

      parent * own
    end

    def self.page!(params)
      limit = params.fetch('limit', 50)
      offset = params.fetch('offset', 0)
      unless limit.is_a?(Integer) && (1..100).cover?(limit) && offset.is_a?(Integer) && offset >= 0
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'limit must be 1..100 and offset nonnegative')
      end
      [limit, offset]
    end
  end
end
