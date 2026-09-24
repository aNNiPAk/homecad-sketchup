module HomeCAD
  module Runtime
    module Dispatcher
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
        else
          raise BridgeError.new(-32601, 'unsupported_operation', "unknown method: #{method}")
        end
      end

      def self.empty!(params)
        raise BridgeError.new(-32602, 'invalid_request', 'params must be an empty object') unless params == {}
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
          'ruby_extension_version' => HomeCAD::VERSION }
      end

      def self.status
        { 'ruby_extension_version' => HomeCAD::VERSION,
          'protocol_version' => HomeCAD::PROTOCOL_VERSION,
          'sketchup_version' => Sketchup.version,
          'model_name' => model_name(active_model!),
          'connection_status' => 'connected' }
      end

      def self.model_info
        model = active_model!
        { 'name' => model_name(model), 'title' => model.title,
          'path' => model.path.empty? ? nil : model.path,
          'guid' => model.guid, 'modified' => model.modified?,
          'root_entity_count' => model.entities.length,
          'active_entity_count' => model.active_entities.length,
          'selection_count' => model.selection.length }
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
