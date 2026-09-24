module HomeCAD
  module Runtime
    class Server
      TICK_SECONDS = 0.05
      READ_BYTES = 16_384

      Client = Struct.new(:socket, :reader, :outbound, :handshake_done,
                          :close_after_write, :last_activity, keyword_init: true)

      def initialize(port: Config.port)
        @port = port
        @clients = {}
      end

      def start
        return if @listener

        @listener = TCPServer.new(Config::HOST, @port)
        @timer = UI.start_timer(TICK_SECONDS, true) { tick }
        Logging.write('INFO', "listening on #{Config::HOST}:#{@port}")
      rescue StandardError => e
        @listener&.close
        @listener = nil
        Logging.write('ERROR', "start failed: #{e.class}: #{e.message}")
        raise
      end

      def stop
        UI.stop_timer(@timer) if @timer
        @timer = nil
        @clients.values.each { |client| close_client(client) }
        @listener&.close
        @listener = nil
      end

      # Public for the Ruby transport tests; UI.start_timer calls the same method.
      def tick
        return unless @listener

        accept_clients
        @clients.values.each do |client|
          next unless @clients.key?(client.socket)

          if monotonic - client.last_activity > Config::CLIENT_IDLE_SECONDS
            close_client(client)
            next
          end
          read_client(client) unless client.close_after_write
          flush_client(client) if @clients.key?(client.socket)
        end
      rescue StandardError => e
        Logging.write('ERROR', "timer error: #{e.class}: #{e.message}")
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def accept_clients
        8.times do
          socket = @listener.accept_nonblock
          if @clients.length >= Config::MAX_CLIENTS
            socket.close
            next
          end
          @clients[socket] = Client.new(socket: socket, reader: Framing::Reader.new,
                                        outbound: ''.b, handshake_done: false,
                                        close_after_write: false, last_activity: monotonic)
        end
      rescue IO::WaitReadable
        nil
      end

      def read_client(client)
        bytes = client.socket.read_nonblock(READ_BYTES)
        client.last_activity = monotonic
        client.reader.feed(bytes).each do |body|
          process_frame(client, body)
          break if client.close_after_write
        end
      rescue IO::WaitReadable
        nil
      rescue EOFError, Errno::ECONNRESET, IOError
        close_client(client)
      rescue BridgeError => e
        queue_response(client, e.to_response(nil))
        client.close_after_write = true
      rescue StandardError => e
        Logging.write('ERROR', "read error: #{e.class}: #{e.message}")
        close_client(client)
      end

      def process_frame(client, body)
        request = JSON.parse(body)
        id = request.is_a?(Hash) ? request['id'] : nil
        begin
          result = Dispatcher.dispatch(request, handshake_done: client.handshake_done)
          client.handshake_done = true unless client.handshake_done
          queue_response(client, 'jsonrpc' => '2.0', 'id' => id, 'result' => result)
          client.close_after_write = true if request['method'] != 'hello'
        rescue BridgeError => e
          queue_response(client, e.to_response(id))
          client.close_after_write = true
        rescue StandardError => e
          Logging.write('ERROR', "dispatch error: #{e.class}: #{e.message}")
          queue_response(client, BridgeError.new(-32603, 'internal_error',
                                                 'SketchUp request failed; see Ruby Console').to_response(id))
          client.close_after_write = true
        end
      rescue JSON::ParserError
        queue_response(client, BridgeError.new(-32700, 'invalid_request', 'invalid JSON').to_response(nil))
        client.close_after_write = true
      end

      def queue_response(client, response)
        client.outbound << Framing.encode(JSON.generate(response))
      rescue StandardError => e
        Logging.write('ERROR', "response error: #{e.class}: #{e.message}")
        close_client(client)
      end

      def flush_client(client)
        unless client.outbound.empty?
          written = client.socket.write_nonblock(client.outbound)
          client.outbound.slice!(0, written)
          client.last_activity = monotonic if written.positive?
        end
        close_client(client) if client.outbound.empty? && client.close_after_write
      rescue IO::WaitWritable
        nil
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        close_client(client)
      end

      def close_client(client)
        @clients.delete(client.socket)
        client.socket.close unless client.socket.closed?
      rescue IOError
        nil
      end
    end
  end
end
