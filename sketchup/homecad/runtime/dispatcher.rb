module HomeCAD
  module Runtime
    module Dispatcher
      CAPABILITIES = %w[
        model.info.v1
        scene.inspect.v1
        scene.measure.v1
        view.capture.v1
        scene.undo.v1
        geometry.primitive.v1
        architecture.core.v1
        furniture.core.v1
        furniture.hardware.v1
        furniture.presets.v1
        manufacturing.cutlist.v1
        project.defaults.v1
        kitchen.run.v1
        kitchen.service_zone.v1
        kitchen.corner_run.v1
        kitchen.variants.v1
        kitchen.composition.v1
        electrical.points.v1
        electrical.circuits.v1
        electrical.panels.v1
        electrical.consumers.v1
        electrical.routes.v1
        electrical.load.v1
        electrical.rules.v1
      ].freeze

      def self.dispatch(request, handshake_done:)
        validate_request!(request)
        method = request['method']
        params = request['params']

        unless handshake_done
          raise BridgeError.new(-32600, 'invalid_request', 'hello must be the first request') unless method == 'hello'

          return hello(params)
        end

        case method
        when 'homecad_status' then empty!(params); status
        when 'get_model_info' then empty!(params); model_info
        when 'list_objects' then Inspection.list(active_model!, params)
        when 'find_objects' then Inspection.find(active_model!, params)
        when 'get_object' then Inspection.get(active_model!, params)
        when 'get_selection' then Inspection.selection(active_model!, params)
        when 'measure' then Measurement.measure(active_model!, params)
        when 'capture_view' then Capture.capture(active_model!, params)
        when 'undo' then undo(active_model!, params)
        when 'create_group', 'create_face', 'create_edge', 'create_box', 'create_circle', 'create_arc', 'create_polygon'
          Primitives.dispatch(active_model!, method, params)
        when 'push_pull', 'follow_me', 'transform_object', 'boolean_operation'
          Mutations.dispatch(active_model!, method, params)
        when 'get_wall_frame', 'create_wall', 'create_opening', 'create_door', 'create_window',
             'create_niche', 'create_column', 'update_architecture_object',
             'delete_architecture_object', 'create_room', 'detect_rooms'
          Architecture.dispatch(active_model!, method, params)
        when 'get_furniture_frame', 'list_furniture_parts', 'list_hardware_catalog',
             'plan_cabinet_drawer', 'create_cabinet',
             'update_furniture_object', 'delete_furniture_object'
          Furniture.dispatch(active_model!, method, params)
        when 'create_outlet', 'create_switch', 'create_electrical_point',
             'update_electrical_point', 'delete_electrical_point', 'validate_electrical',
             'assign_to_circuit', 'create_circuit', 'get_circuit', 'list_circuits',
             'update_circuit', 'delete_circuit'
          Electrical.dispatch(active_model!, method, params)
        when 'create_distribution_panel', 'get_distribution_panel', 'update_distribution_panel',
             'delete_distribution_panel', 'assign_circuit_to_panel', 'create_consumer',
             'get_consumer', 'list_consumers', 'update_consumer', 'delete_consumer',
             'connect_consumer', 'find_unpowered_consumers', 'get_circuit_load',
             'create_cable_route', 'get_cable_route', 'list_cable_routes',
             'update_cable_route', 'delete_cable_route', 'get_electrical_ruleset'
          ElectricalSystem.dispatch(active_model!, method, params)
        when 'get_project_settings' then empty!(params); ProjectSettings.read(active_model!)
        when 'update_project_settings' then
          Primitives.check_keys!(params, %w[changes])
          ProjectSettings.update(active_model!, params['changes'])
        when 'list_furniture_presets' then empty!(params); FurniturePresets.list
        when 'get_furniture_preset' then
          Primitives.check_keys!(params, %w[preset_id])
          FurniturePresets.get(params['preset_id'])
        when 'create_cabinet_from_preset' then
          Primitives.check_keys!(params, %w[preset_id overrides])
          preset_params, source = FurniturePresets.resolve(active_model!, params['preset_id'],
            params.fetch('overrides', {}))
          Furniture.create_cabinet(active_model!, preset_params, source: source)
        when 'generate_cutlist' then Cutlist.generate(active_model!, params)
        when 'plan_kitchen_run', 'plan_corner_kitchen_run', 'apply_kitchen_run', 'validate_kitchen',
             'update_kitchen_run', 'delete_kitchen_run'
          Kitchen.dispatch(active_model!, method, params)
        else
          raise BridgeError.new(-32601, 'unsupported_operation', "unknown method: #{method}")
        end
      end

      def self.empty!(params)
        raise BridgeError.new(-32602, 'invalid_request', 'params must be an empty object') unless params == {}
      end

      def self.undo(_model, params)
        empty!(params)
        accepted = Sketchup.send_action('editUndo:')
        raise BridgeError.new(-32007, 'undo_unavailable', 'SketchUp did not accept Undo') unless accepted

        { 'status' => 'queued', 'actions' => 1, 'operation' => 'undo' }
      end

      def self.validate_request!(request)
        valid = request.is_a?(Hash) && request['jsonrpc'] == '2.0' &&
                request['id'].is_a?(Integer) && request['method'].is_a?(String) &&
                request['params'].is_a?(Hash)
        raise BridgeError.new(-32600, 'invalid_request', 'invalid JSON-RPC request') unless valid
      end

      def self.hello(params)
        protocol = params['protocol_version']
        client = params['client_version']
        if protocol != HomeCAD::PROTOCOL_VERSION || !client.is_a?(String) ||
           !/\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(client) || client.split('.').first.to_i != 0
          raise BridgeError.new(-32001, 'incompatible_version',
                                "Expected protocol #{HomeCAD::PROTOCOL_VERSION} and client 0.x.x; received protocol #{protocol.inspect}, client #{client.inspect}")
        end

        { 'protocol_version' => HomeCAD::PROTOCOL_VERSION,
          'ruby_extension_version' => HomeCAD::VERSION,
          'capabilities' => CAPABILITIES }
      end

      def self.status
        { 'ruby_extension_version' => HomeCAD::VERSION,
          'protocol_version' => HomeCAD::PROTOCOL_VERSION,
          'capabilities' => CAPABILITIES,
          'sketchup_version' => Sketchup.version,
          'model_name' => model_name(active_model!),
          'connection_status' => 'connected' }
      end

      def self.model_info
        model = active_model!
        fixture_id = model.get_attribute('HomeCADDev', 'fixture_id') if model.respond_to?(:get_attribute)
        disposable = model.get_attribute('HomeCADDev', 'disposable') if model.respond_to?(:get_attribute)
        dev_fixture = fixture_id == 'homecad-smoke-v1' && disposable == true
        { 'name' => model_name(model), 'title' => model.title,
          'path' => model.path.empty? ? nil : model.path,
          'guid' => model.guid, 'modified' => model.modified?,
          'root_entity_count' => model.entities.length,
          'active_entity_count' => model.active_entities.length,
          'selection_count' => model.selection.length,
          'dev_fixture' => dev_fixture,
          'dev_fixture_id' => dev_fixture ? fixture_id : nil }
      end

      def self.active_model!
        model = Sketchup.active_model
        raise BridgeError.new(-32603, 'internal_error', 'No active SketchUp model') unless model

        model
      end

      def self.model_name(model)
        return model.name unless model.name.empty?
        return model.title unless model.title.empty?

        '(Untitled)'
      end
    end
  end
end
