module HomeCAD
  module Runtime
    module Logging
      LEVELS = { 'DEBUG' => 0, 'INFO' => 1, 'WARN' => 2, 'ERROR' => 3 }.freeze

      def self.write(level, message)
        threshold = ENV.fetch('HOMECAD_LOG_LEVEL', 'INFO').upcase
        threshold = 'INFO' unless LEVELS.key?(threshold)
        return if LEVELS.fetch(level) < LEVELS.fetch(threshold)

        warn("[HomeCAD] #{level} #{message}")
      end
    end
  end
end
