module HomeCAD
  module Runtime
    class BridgeError < StandardError
      attr_reader :code, :category

      def initialize(code, category, message)
        super(message)
        @code = code
        @category = category
      end

      def to_response(id)
        {
          'jsonrpc' => '2.0', 'id' => id,
          'error' => { 'code' => code, 'message' => message,
                       'data' => { 'category' => category } }
        }
      end
    end
  end
end
