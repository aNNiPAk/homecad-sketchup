module HomeCAD
  module Geometry
    MAX_SEGMENTS = 512
    MAX_POINTS = 512
    MIN_LENGTH_MM = 0.01

    def self.finite_number(value, name)
      unless value.is_a?(Numeric) && value.finite?
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must be a finite number")
      end
      value.to_f
    end

    def self.positive_length(value, name)
      number = finite_number(value, name)
      if number <= 0.0
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must be greater than zero")
      end
      number
    end

    def self.point_mm(value, name)
      unless value.is_a?(Array) && value.length == 3
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must be [x_mm, y_mm, z_mm]")
      end
      coordinates = value.each_with_index.map { |coordinate, index| finite_number(coordinate, "#{name}[#{index}]") }
      Geom::Point3d.new(*coordinates.map { |coordinate| Units.mm_to_internal(coordinate) })
    end

    def self.vector(value, name)
      unless value.is_a?(Array) && value.length == 3
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must be a three-number vector")
      end
      coordinates = value.each_with_index.map { |coordinate, index| finite_number(coordinate, "#{name}[#{index}]") }
      vector = Geom::Vector3d.new(*coordinates)
      if !vector.respond_to?(:length) || vector.length <= 1e-12
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must not be zero")
      end
      vector.length = 1.0
      vector
    end

    def self.vector_mm(value, name)
      unless value.is_a?(Array) && value.length == 3
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must be [x_mm, y_mm, z_mm]")
      end
      coordinates = value.each_with_index.map { |coordinate, index| finite_number(coordinate, "#{name}[#{index}]") }
      Geom::Vector3d.new(*coordinates.map { |coordinate| Units.mm_to_internal(coordinate) })
    end

    def self.path_points(value, name: 'path_points_mm')
      unless value.is_a?(Array) && (2..MAX_POINTS).cover?(value.length)
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must contain 2..#{MAX_POINTS} points")
      end
      points = value.each_with_index.map { |point, index| point_mm(point, "#{name}[#{index}]") }
      tolerance = Units.mm_to_internal(MIN_LENGTH_MM)
      if points.each_cons(2).any? { |first, last| first.distance(last) <= tolerance }
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'adjacent path points must be distinct')
      end
      points
    end

    def self.segments(value, name, minimum: 3)
      unless value.is_a?(Integer) && (minimum..MAX_SEGMENTS).cover?(value)
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must be #{minimum}..#{MAX_SEGMENTS}")
      end
      value
    end

    def self.points(value, name: 'points_mm')
      unless value.is_a?(Array) && (3..MAX_POINTS).cover?(value.length)
        raise Runtime::BridgeError.new(-32602, 'invalid_request', "#{name} must contain 3..#{MAX_POINTS} points")
      end
      points = value.each_with_index.map { |point, index| point_mm(point, "#{name}[#{index}]") }
      tolerance = Units.mm_to_internal(MIN_LENGTH_MM)
      distinct = []
      points.each do |point|
        distinct << point unless distinct.any? { |existing| existing.distance(point) <= tolerance }
      end
      if distinct.length < 3
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'points_mm must contain at least three distinct points')
      end
      points
    end

    def self.metadata_type!(type)
      unless %w[primitive.group primitive.face primitive.edge primitive.box primitive.circle
                primitive.arc primitive.polygon primitive.boolean].include?(type)
        raise Runtime::BridgeError.new(-32602, 'invalid_request', 'unsupported primitive type')
      end
      type
    end
  end
end
