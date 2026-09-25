module HomeCAD
  module Serializer
    LEVELS = %w[summary standard detailed].freeze

    def self.serialize(entry, level: 'summary')
      raise Runtime::BridgeError.new(-32602, 'invalid_request', 'invalid detail level') unless LEVELS.include?(level)

      entity = entry.entity
      identity = Targeting.identity(entry)
      data = Targeting.metadata(entity)
      result = { 'identity' => identity, 'homecad_id' => identity['homecad_id'],
                 'persistent_id' => identity['persistent_id'], 'entity_id' => identity['entity_id'],
                 'entity_type' => Scene.type(entity),
                 'homecad_type' => data['type'],
                 'name' => entity.respond_to?(:name) ? entity.name.to_s : '' }
      return result if level == 'summary'

      result.merge!('valid' => entity.respond_to?(:valid?) ? entity.valid? : true,
                    'deleted' => entity.respond_to?(:deleted?) ? entity.deleted? : false,
                    'tag' => entity.respond_to?(:layer) && entity.layer ? entity.layer.name : nil,
                    'material' => material_name(entity),
                    'hidden' => entity.respond_to?(:hidden?) ? entity.hidden? : false,
                    'visible' => visible?(entity),
                    'locked' => entity.respond_to?(:locked?) ? entity.locked? : false,
                    'bbox_mm' => bounds(entry),
                    'bbox_dimensions_mm' => bbox_dimensions(entry),
                    'context' => entry.parent ? 'nested' : 'root',
                    'parent' => parent_identity(entry))
      return result if level == 'standard'

      result.merge!('metadata' => safe_value(data),
                    'transformation' => transformation(entry),
                    'children' => child_summary(entity))
      if data['type'].to_s.start_with?('architecture.') && defined?(ArchitectureData)
        result['parameters'] = safe_value(ArchitectureData.read_params(entity))
        result['relationships'] = safe_value(ArchitectureData.read_relationships(entity))
      elsif data['type'] == 'furniture.cabinet' && defined?(FurnitureData)
        result['parameters'] = safe_value(FurnitureData.read_params(entity))
        result['relationships'] = safe_value(FurnitureData.read_relationships(entity))
      end
      result
    end

    def self.material_name(entity)
      return nil unless entity.respond_to?(:material) && entity.material

      entity.material.name
    end

    def self.visible?(entity)
      return false if entity.respond_to?(:hidden?) && entity.hidden?

      layer = entity.respond_to?(:layer) ? entity.layer : nil
      layer.nil? || !layer.respond_to?(:visible?) || layer.visible?
    end

    def self.parent_identity(entry)
      return nil unless entry.parent

      parent = Scene::Entry.new(entity: entry.parent, parent: nil,
                                path: entry.path[0...-1], transform: nil)
      Targeting.identity(parent)
    end

    def self.bounds(entry)
      entity = entry.entity
      return nil unless entity.respond_to?(:bounds)

      box = entity.bounds
      return nil if box.nil? || box.empty?

      points = (0..7).map do |index|
        point = box.corner(index)
        entry.transform ? point.transform(entry.transform) : point
      end
      min = [points.map(&:x).min, points.map(&:y).min, points.map(&:z).min]
      max = [points.map(&:x).max, points.map(&:y).max, points.map(&:z).max]
      { 'min' => min.map { |v| Units.internal_to_mm(v) },
        'max' => max.map { |v| Units.internal_to_mm(v) } }
    end

    def self.bbox_dimensions(entry)
      box = bounds(entry)
      return nil unless box

      values = box['max'].zip(box['min']).map { |upper, lower| upper - lower }
      { 'width' => values[0], 'depth' => values[1], 'height' => values[2] }
    end

    def self.transformation(entry)
      composed = Scene.compose(entry.transform, entry.entity)
      return nil unless composed

      values = composed.to_a.map(&:to_f)
      [12, 13, 14].each { |index| values[index] = Units.internal_to_mm(values[index]) }
      { 'matrix' => values, 'translation_unit' => 'mm' }
    end

    def self.child_summary(entity)
      children = Scene.children(entity)
      return nil unless children

      { 'total' => children.length,
        'by_type' => children.each_with_object(Hash.new(0)) { |child, counts| counts[Scene.type(child)] += 1 } }
    end

    def self.safe_value(value, depth = 0)
      return nil if depth > 3
      case value
      when String, Numeric, TrueClass, FalseClass, NilClass then value
      when Array then value.first(50).map { |item| safe_value(item, depth + 1) }
      when Hash then value.first(50).to_h { |key, item| [key.to_s, safe_value(item, depth + 1)] }
      else value.to_s.slice(0, 256)
      end
    end
  end
end
