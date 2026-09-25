module HomeCAD
  module Geometry
    MAX_SEGMENTS = 512
    MAX_POINTS = 512
    MIN_LENGTH_MM = 0.01
    RIGID_TRANSFORM_TOLERANCE = 1e-6

    # Push/pull distances are public world-space millimeters. They are equal to
    # the local distance only when the parent transform preserves lengths.
    def self.rigid_transform?(transformation, tolerance: RIGID_TRANSFORM_TOLERANCE)
      return false unless transformation.respond_to?(:to_a)

      matrix = transformation.to_a
      return false unless matrix.is_a?(Array) && matrix.length == 16 && matrix.all? { |value| value.is_a?(Numeric) && value.finite? }
      return false unless [3, 7, 11].all? { |index| matrix[index].abs <= tolerance } &&
                          (matrix[15] - 1.0).abs <= tolerance

      # Geom::Transformation#xaxis/yaxis/zaxis report normalized directions.
      # Read the linear columns from the documented 16-value matrix so scale is
      # still visible, then test unit length, orthogonality, and handedness.
      x_axis = Geom::Vector3d.new(*matrix.values_at(0, 1, 2))
      y_axis = Geom::Vector3d.new(*matrix.values_at(4, 5, 6))
      z_axis = Geom::Vector3d.new(*matrix.values_at(8, 9, 10))
      axes = [x_axis, y_axis, z_axis]
      return false unless axes.all? { |axis| axis.respond_to?(:length) && axis.length.finite? }
      return false unless axes.all? { |axis| (axis.length - 1.0).abs <= tolerance }
      return false unless x_axis.dot(y_axis).abs <= tolerance &&
                          x_axis.dot(z_axis).abs <= tolerance && y_axis.dot(z_axis).abs <= tolerance

      # Require a right-handed basis: reflections reverse its sign.
      determinant = x_axis.cross(y_axis).dot(z_axis)
      (determinant - 1.0).abs <= tolerance
    rescue StandardError
      false
    end

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
