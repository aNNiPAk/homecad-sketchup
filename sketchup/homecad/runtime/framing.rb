module HomeCAD
  module Runtime
    module Framing
      def self.encode(body)
        bytes = body.b
        unless (1..Config::MAX_FRAME_BYTES).cover?(bytes.bytesize)
          raise BridgeError.new(-32600, 'invalid_request', 'frame length out of range')
        end

        [bytes.bytesize].pack('N') + bytes
      end

      class Reader
        def initialize
          @buffer = ''.b
          @expected = nil
        end

        def feed(bytes)
          @buffer << bytes.b
          frames = []
          loop do
            if @expected.nil?
              break if @buffer.bytesize < 4

              @expected = @buffer.slice!(0, 4).unpack1('N')
              unless (1..Config::MAX_FRAME_BYTES).cover?(@expected)
                raise BridgeError.new(-32600, 'invalid_request', 'frame length out of range')
              end
            end
            break if @buffer.bytesize < @expected

            frames << @buffer.slice!(0, @expected)
            @expected = nil
          end
          frames
        end
      end
    end
  end
end
