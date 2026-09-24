module HomeCAD
  module Runtime
    module Config
      HOST = '127.0.0.1'
      DEFAULT_PORT = 37_941
      MAX_FRAME_BYTES = 1_048_576
      CLIENT_IDLE_SECONDS = 10
      MAX_CLIENTS = 8

      def self.port
        raw = ENV.fetch('HOMECAD_PORT', DEFAULT_PORT.to_s)
        value = Integer(raw, 10)
        raise ArgumentError, 'HOMECAD_PORT must be 1..65535' unless (1..65_535).cover?(value)

        value
      rescue ArgumentError
        raise ArgumentError, 'HOMECAD_PORT must be 1..65535'
      end
    end
  end
end
