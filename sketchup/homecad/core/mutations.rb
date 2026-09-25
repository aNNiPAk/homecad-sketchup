module HomeCAD
  module Mutations
    TRANSFORM_TYPES = %w[translate rotate scale].freeze
    BOOLEAN_TYPES = %w[union difference intersect].freeze

    def self.dispatch(model, method, params)
      case method
      when 'push_pull' then push_pull(model, params)
      when 'follow_me' then follow_me(model, params)
      when 'transform_object' then transform_object(model, params)
      when 'boolean_operation' then boolean_operation(model, params)
      else
        raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "unknown mutation: #{method}")
      end
    end

    def self.push_pull(model, params)
      Primitives.check_keys!(params, %w[target distance_mm])
      entry = resolve!(model, params['target'])
      MutationPolicy.validate_target!(entry, model: model)
      face = entry.entity
      MutationPolicy.require_type!(face, Sketchup::Face, 'target')
      group = nested_group!(entry, model)
      unless Geometry.rigid_transform?(group.transformation)
        raise Runtime::BridgeError.new(-32008, 'constraint_violation',
          'push_pull distance_mm is world-space; the parent Group must not have scale, shear, or reflection')
      end
      distance = Geometry.finite_number(params['distance_mm'], 'distance_mm')
      if distance.abs < Geometry::MIN_LENGTH_MM
        Primitives.invalid!('distance_mm magnitude must be at least 0.01')
      end

      run_update(model, 'push_pull', group) do
        face.pushpull(Units.mm_to_internal(distance))
      end
    end

    def self.follow_me(model, params)
      Primitives.check_keys!(params, %w[target path_points_mm])
      entry = resolve!(model, params['target'])
      MutationPolicy.validate_target!(entry, model: model)
      face = entry.entity
      MutationPolicy.require_type!(face, Sketchup::Face, 'target')
      group = nested_group!(entry, model)
      world_points = Geometry.path_points(params['path_points_mm'])
      inverse = group.transformation.inverse
      local_points = world_points.map { |point| inverse * point }

      run_update(model, 'follow_me', group) do
        edges = local_points.each_cons(2).map do |first, last|
          edge = group.entities.add_line(first, last)
          Primitives.geometry_created!(edge, 'SketchUp could not create a follow-me path edge')
        end
        result = face.followme(edges)
        Primitives.geometry_error!('SketchUp could not sweep the face along this path') unless result
        retained_edges = edges.select do |edge|
          next false if edge.respond_to?(:valid?) && !edge.valid?

          if edge.respond_to?(:faces)
            edge.faces.empty? ? (edge.erase!; false) : true
          else
            true
          end
        end
        retained_edges.empty? ? [] : [
          'Some follow_me path edges are shared with the swept geometry and were retained as geometry boundaries.'
        ]
      end
    end

    def self.transform_object(model, params)
      Primitives.check_keys!(params, %w[target transform])
      entry = resolve!(model, params['target'])
      entity = MutationPolicy.validate_target!(entry, model: model)
      root_target!(entry, 'transform target')
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        Primitives.invalid!('transform target must be a Group or ComponentInstance')
      end
      specification = params['transform']
      unless specification.is_a?(Hash) && TRANSFORM_TYPES.include?(specification['type'])
        Primitives.invalid!('transform.type must be translate, rotate, or scale')
      end
      transformation = build_transformation(specification)

      run_update(model, 'transform_object', entity) do
        Primitives.geometry_error!('SketchUp could not transform this object') unless entity.transform!(transformation)
      end
    end

    def self.boolean_operation(model, params)
      Primitives.check_keys!(params, %w[target tool operation])
      operation = params['operation']
      Primitives.invalid!('operation must be union, difference, or intersect') unless BOOLEAN_TYPES.include?(operation)
      target_entry = resolve!(model, params['target'])
      tool_entry = resolve!(model, params['tool'])
      target = MutationPolicy.validate_target!(target_entry, model: model)
      tool = MutationPolicy.validate_target!(tool_entry, model: model)
      root_target!(target_entry, 'target')
      root_target!(tool_entry, 'tool')
      if target.equal?(tool)
        Primitives.invalid!('target and tool must identify different objects')
      end
      unless target.is_a?(Sketchup::Group) || target.is_a?(Sketchup::ComponentInstance)
        Primitives.invalid!('target must be a Group or ComponentInstance')
      end
      unless tool.is_a?(Sketchup::Group) || tool.is_a?(Sketchup::ComponentInstance)
        Primitives.invalid!('tool must be a Group or ComponentInstance')
      end
      require_solid!(target, 'target')
      require_solid!(tool, 'tool')
      method = { 'union' => :union, 'difference' => :subtract, 'intersect' => :intersect }.fetch(operation)
      unless target.respond_to?(method) && tool.respond_to?(method)
        raise Runtime::BridgeError.new(-32601, 'unsupported_operation', "SketchUp does not support #{operation}")
      end

      begin
        HomeCAD::Operation.run("Boolean #{operation}", model: model) do
          entities = model.entities
          target_copy = entities.add_instance(target.definition, target.transformation)
          tool_copy = entities.add_instance(tool.definition, tool.transformation)
          Primitives.geometry_created!(target_copy, 'Could not copy boolean target')
          Primitives.geometry_created!(tool_copy, 'Could not copy boolean tool')
          # SketchUp's subtract parameter docs describe the argument as the
          # destination to subtract this receiver from. Use tool as receiver
          # and target as argument to obtain target - tool (verified in SU 26).
          result = if operation == 'difference'
                     tool_copy.subtract(target_copy)
                   else
                     target_copy.public_send(method, tool_copy)
                   end
          Primitives.geometry_error!("SketchUp #{operation} failed; both operands must be manifold solids") unless result
          Primitives.geometry_created!(result, "SketchUp #{operation} returned an invalid result")
          target_copy.erase! if target_copy.valid? && !target_copy.equal?(result)
          tool_copy.erase! if tool_copy.valid? && !tool_copy.equal?(result)
          Metadata.create!(result, type: 'primitive.boolean')
          serialized = serialize_root(result)
          MutationResult.success(operation: 'boolean_operation', created: [serialized], revision: 1)
        end
      rescue Runtime::BridgeError
        raise
      rescue StandardError => error
        raise Runtime::BridgeError.new(-32009, 'geometry_error', "boolean_operation failed: #{error.message}")
      end
    end

    def self.run_update(model, operation, entity)
      HomeCAD::Operation.run(operation.tr('_', ' ').capitalize, model: model) do
        warnings = yield || []
        metadata = Metadata.increment_revision!(entity)
        serialized = serialize_root(entity)
        MutationResult.success(operation: operation, updated: [serialized], warnings: warnings,
                               revision: metadata['revision'])
      end
    rescue Runtime::BridgeError
      raise
    rescue StandardError => error
      raise Runtime::BridgeError.new(-32009, 'geometry_error', "#{operation} failed: #{error.message}")
    end

    def self.resolve!(model, selector)
      Targeting.resolve_one(model, selector)
    end

    def self.root_target!(entry, label)
      return entry.entity if entry.parent.nil? && entry.path.length == 1

      raise Runtime::BridgeError.new(-32008, 'constraint_violation', "#{label} must be a root-level object")
    end

    def self.nested_group!(entry, model)
      group = entry.parent
      unless group.is_a?(Sketchup::Group) && entry.path.length == 2
        raise Runtime::BridgeError.new(-32008, 'constraint_violation',
                                       'push_pull and follow_me require a Face inside a root-level Group')
      end
      MutationPolicy.validate_target!(Scene::Entry.new(entity: group, parent: nil,
                                                       path: [Scene.id(group)], transform: nil),
                                      model: model)
      definition = group.definition
      if definition.respond_to?(:instances) && definition.instances.length > 1
        raise Runtime::BridgeError.new(-32008, 'constraint_violation',
                                       'shared Group definitions cannot be edited by push_pull or follow_me')
      end
      group
    end

    def self.build_transformation(specification)
      case specification['type']
      when 'translate'
        Primitives.check_keys!(specification, %w[type vector_mm])
        vector = Geometry.vector_mm(specification['vector_mm'], 'transform.vector_mm')
        if vector.length <= Units.mm_to_internal(Geometry::MIN_LENGTH_MM)
          Primitives.invalid!('transform.vector_mm must have magnitude of at least 0.01')
        end
        Geom::Transformation.translation(vector)
      when 'rotate'
        Primitives.check_keys!(specification,
                               %w[type axis_point_mm axis_vector angle_degrees])
        point = Geometry.point_mm(specification['axis_point_mm'], 'transform.axis_point_mm')
        axis = Geometry.vector(specification['axis_vector'], 'transform.axis_vector')
        angle = Geometry.finite_number(specification['angle_degrees'], 'transform.angle_degrees')
        Primitives.invalid!('transform.angle_degrees must be nonzero') if angle.abs <= 1e-9
        Geom::Transformation.rotation(point, axis, Primitives.radians(angle))
      when 'scale'
        Primitives.check_keys!(specification, %w[type origin_mm factors])
        origin = Geometry.point_mm(specification.fetch('origin_mm', [0, 0, 0]), 'transform.origin_mm')
        factors = specification['factors']
        unless factors.is_a?(Array) && factors.length == 3
          Primitives.invalid!('transform.factors must be [x, y, z]')
        end
        values = factors.each_with_index.map { |factor, index| Geometry.positive_length(factor, "transform.factors[#{index}]") }
        Geom::Transformation.scaling(origin, *values)
      end
    end

    def self.require_solid!(entity, label)
      definition = entity.definition
      unless definition.respond_to?(:manifold?) && definition.manifold?
        raise Runtime::BridgeError.new(-32008, 'constraint_violation', "#{label} must be a manifold solid")
      end
    end

    def self.serialize_root(entity)
      entry = Scene::Entry.new(entity: entity, parent: nil, path: [Scene.id(entity)], transform: nil)
      Serializer.serialize(entry, level: 'detailed')
    end
  end
end
