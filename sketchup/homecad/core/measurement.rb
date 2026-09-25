module HomeCAD
  module Measurement
    KINDS = %w[bounds bbox_dimensions center_distance bbox_distance face_area edge_length].freeze

    def self.measure(model, params)
      Inspection.check_keys!(params, %w[kind target other_target])
      kind = params['kind']
      Inspection.invalid!('unsupported measurement kind') unless KINDS.include?(kind)
      first = Targeting.resolve_one(model, params['target'])
      second = nil
      if %w[center_distance bbox_distance].include?(kind)
        second = Targeting.resolve_one(model, params['other_target'])
      elsif params.key?('other_target')
        Inspection.invalid!('other_target applies only to distance measurements')
      end
      targets = [first, second].compact.map { |entry| Targeting.identity(entry) }
      value, unit = case kind
                    when 'bounds' then [required_bounds(first), 'mm']
                    when 'bbox_dimensions' then [Serializer.bbox_dimensions(first) || geometry_error!, 'mm']
                    when 'center_distance' then [center_distance(first, second), 'mm']
                    when 'bbox_distance' then [bbox_distance(first, second), 'mm']
                    when 'face_area' then [face_area(first), 'mm²']
                    when 'edge_length' then [edge_length(first), 'mm']
                    end
      { 'kind' => kind, 'targets' => targets, 'unit' => unit, 'value' => value }
    end

    def self.required_bounds(entry)
      Serializer.bounds(entry) || geometry_error!
    end

    def self.center_distance(a, b)
      box_a = required_bounds(a)
      box_b = required_bounds(b)
      squared = (0..2).sum do |i|
        delta = (box_a['min'][i] + box_a['max'][i] - box_b['min'][i] - box_b['max'][i]) / 2.0
        delta * delta
      end
      Math.sqrt(squared)
    end

    def self.bbox_distance(a, b)
      box_a = required_bounds(a)
      box_b = required_bounds(b)
      squared = (0..2).sum do |i|
        gap = [box_a['min'][i] - box_b['max'][i], box_b['min'][i] - box_a['max'][i], 0].max
        gap * gap
      end
      Math.sqrt(squared)
    end

    def self.face_area(entry)
      Inspection.invalid!('target must be a Face') unless Scene.type(entry.entity) == 'Face'

      area = entry.transform ? entry.entity.area(entry.transform) : entry.entity.area
      area.to_f * Units::MM_PER_INCH**2
    end

    def self.edge_length(entry)
      Inspection.invalid!('target must be an Edge') unless Scene.type(entry.entity) == 'Edge'

      length = entry.transform ? entry.entity.length(entry.transform) : entry.entity.length
      Units.internal_to_mm(length)
    end

    def self.geometry_error!
      raise Runtime::BridgeError.new(-32005, 'geometry_error', 'target has no measurable bounds')
    end
  end
end
