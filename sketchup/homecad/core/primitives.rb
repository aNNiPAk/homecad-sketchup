module HomeCAD
  module Primitives
    CREATE_METHODS = %w[create_group create_face create_edge create_box create_circle create_arc create_polygon].freeze

    def self.dispatch(model, method, params)
      raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "unknown primitive method: #{method}") unless CREATE_METHODS.include?(method)

      case method
      when 'create_group' then create_group(model, params)
      when 'create_face' then create_face(model, params)
      when 'create_edge' then create_edge(model, params)
      when 'create_box' then create_box(model, params)
      when 'create_circle' then create_circle(model, params)
      when 'create_arc' then create_arc(model, params)
      when 'create_polygon' then create_polygon(model, params)
      end
    end

    def self.create_group(model, params)
      check_keys!(params, %w[name])
      create(model, 'create_group', 'primitive.group', params) { |_group| }
    end

    def self.create_face(model, params)
      check_keys!(params, %w[points_mm name])
      points = Geometry.points(params['points_mm'])
      create(model, 'create_face', 'primitive.face', params) do |group|
        face = group.entities.add_face(points)
        geometry_created!(face, 'SketchUp could not create a face from these points')
      end
    end

    def self.create_edge(model, params)
      check_keys!(params, %w[start_mm end_mm name])
      start_point = Geometry.point_mm(params['start_mm'], 'start_mm')
      end_point = Geometry.point_mm(params['end_mm'], 'end_mm')
      if start_point.distance(end_point) <= Units.mm_to_internal(Geometry::MIN_LENGTH_MM)
        invalid!('start_mm and end_mm must be distinct')
      end
      create(model, 'create_edge', 'primitive.edge', params) do |group|
        edge = group.entities.add_line(start_point, end_point)
        geometry_created!(edge, 'SketchUp could not create an edge between these points')
      end
    end

    def self.create_box(model, params)
      check_keys!(params, %w[width_mm depth_mm height_mm origin_mm name])
      width = Geometry.positive_length(params['width_mm'], 'width_mm')
      depth = Geometry.positive_length(params['depth_mm'], 'depth_mm')
      height = Geometry.positive_length(params['height_mm'], 'height_mm')
      origin = Geometry.point_mm(params.fetch('origin_mm', [0, 0, 0]), 'origin_mm')
      create(model, 'create_box', 'primitive.box', params) do |group|
        x = Units.mm_to_internal(width)
        y = Units.mm_to_internal(depth)
        z = Units.mm_to_internal(height)
        points = [origin, Geom::Point3d.new(origin.x + x, origin.y, origin.z),
                  Geom::Point3d.new(origin.x + x, origin.y + y, origin.z),
                  Geom::Point3d.new(origin.x, origin.y + y, origin.z)]
        face = group.entities.add_face(points)
        geometry_created!(face, 'SketchUp could not create the box base face')
        face.pushpull(z)
        unless group.valid? && group.bounds && !group.bounds.empty?
          geometry_error!('SketchUp did not create box geometry')
        end
      end
    end

    def self.create_circle(model, params)
      check_keys!(params, %w[center_mm normal radius_mm segments name])
      center = Geometry.point_mm(params.fetch('center_mm', [0, 0, 0]), 'center_mm')
      normal = Geometry.vector(params.fetch('normal', [0, 0, 1]), 'normal')
      radius = Units.mm_to_internal(Geometry.positive_length(params['radius_mm'], 'radius_mm'))
      segments = Geometry.segments(params.fetch('segments', 24), 'segments')
      create(model, 'create_circle', 'primitive.circle', params) do |group|
        edges = group.entities.add_circle(center, normal, radius, segments)
        geometry_created!(edges, 'SketchUp could not create a circle')
      end
    end

    def self.create_arc(model, params)
      check_keys!(params, %w[center_mm normal x_axis radius_mm start_angle_degrees end_angle_degrees segments name])
      center = Geometry.point_mm(params.fetch('center_mm', [0, 0, 0]), 'center_mm')
      normal = Geometry.vector(params.fetch('normal', [0, 0, 1]), 'normal')
      x_axis = Geometry.vector(params.fetch('x_axis', [1, 0, 0]), 'x_axis')
      dot = normal.x * x_axis.x + normal.y * x_axis.y + normal.z * x_axis.z
      invalid!('x_axis must be perpendicular to normal') if dot.abs > 1e-6
      radius = Units.mm_to_internal(Geometry.positive_length(params['radius_mm'], 'radius_mm'))
      start_degrees = Geometry.finite_number(params.fetch('start_angle_degrees', 0), 'start_angle_degrees')
      end_degrees = Geometry.finite_number(params.fetch('end_angle_degrees', 90), 'end_angle_degrees')
      sweep = end_degrees - start_degrees
      if sweep.abs <= 1e-9 || sweep.abs > 360.0
        invalid!('arc sweep must be greater than 0 and at most 360 degrees')
      end
      segments = Geometry.segments(params.fetch('segments', 12), 'segments', minimum: 1)
      create(model, 'create_arc', 'primitive.arc', params) do |group|
        edges = group.entities.add_arc(center, x_axis, normal, radius,
                                       radians(start_degrees), radians(end_degrees), segments)
        geometry_created!(edges, 'SketchUp could not create an arc')
      end
    end

    def self.create_polygon(model, params)
      check_keys!(params, %w[center_mm normal radius_mm sides name])
      center = Geometry.point_mm(params.fetch('center_mm', [0, 0, 0]), 'center_mm')
      normal = Geometry.vector(params.fetch('normal', [0, 0, 1]), 'normal')
      radius = Units.mm_to_internal(Geometry.positive_length(params['radius_mm'], 'radius_mm'))
      sides = Geometry.segments(params['sides'], 'sides')
      x_axis, y_axis = plane_basis(normal)
      points = (0...sides).map do |index|
        angle = 2.0 * Math::PI * index / sides
        center.offset(x_axis, radius * Math.cos(angle)).offset(y_axis, radius * Math.sin(angle))
      end
      create(model, 'create_polygon', 'primitive.polygon', params) do |group|
        face = group.entities.add_face(points)
        geometry_created!(face, 'SketchUp could not create a polygon face')
      end
    end

    def self.create(model, operation, type, params)
      name = params['name']
      invalid!('name must be a string') if !name.nil? && !name.is_a?(String)
      HomeCAD::Operation.run(operation.tr('_', ' ').capitalize, model: model) do
        group = model.entities.add_group
        geometry_created!(group, 'SketchUp could not create a group')
        group.name = name if name && !name.empty?
        Metadata.create!(group, type: Geometry.metadata_type!(type))
        yield(group)
        entry = Scene::Entry.new(entity: group, parent: nil, path: [Scene.id(group)], transform: nil)
        serialized = Serializer.serialize(entry, level: 'detailed')
        MutationResult.success(operation: operation, created: [serialized], revision: 1)
      end
    rescue Runtime::BridgeError
      raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "#{operation} failed: #{error.message}")
    end

    def self.plane_basis(normal)
      reference = normal.x.abs < 0.8 ? Geom::Vector3d.new(1, 0, 0) : Geom::Vector3d.new(0, 1, 0)
      x_axis = normal.cross(reference)
      x_axis.length = 1.0
      y_axis = normal.cross(x_axis)
      y_axis.length = 1.0
      [x_axis, y_axis]
    end

    def self.radians(degrees)
      degrees * Math::PI / 180.0
    end

    def self.geometry_created!(value, message)
      success = value.is_a?(Array) ? !value.empty? && value.none?(&:nil?) : !value.nil? && value != false
      return value if success

      geometry_error!(message)
    end

    def self.check_keys!(params, allowed)
      invalid!('params must be an object') unless params.is_a?(Hash)
      invalid!("unsupported parameters: #{(params.keys - allowed).join(', ')}") unless (params.keys - allowed).empty?
    end

    def self.invalid!(message)
      raise Runtime::BridgeError.new(-32602, 'invalid_request', message)
    end

    def self.geometry_error!(message)
      raise Runtime::BridgeError.new(-32009, 'geometry_error', message)
    end
  end
end
