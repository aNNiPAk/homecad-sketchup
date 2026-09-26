require 'minitest/autorun'
require 'json'
require 'socket'

module UI
  def self.start_timer(*) = 1
  def self.stop_timer(*) = nil
end

FakeModel = Struct.new(:name, :title, :path, :guid, :entities, :active_entities,
                       :selection, :modified, :attributes, keyword_init: true) do
  def modified? = modified
  def get_attribute(dictionary, key, default = nil) = (attributes || {}).fetch([dictionary, key], default)
end

module Sketchup
  def self.version = '2026.0'
  def self.active_model = @model
  def self.active_model=(model)
    @model = model
  end
end

module HomeCAD
  VERSION = '0.1.0'
  PROTOCOL_VERSION = 1
end

root = File.expand_path('../../sketchup/homecad', __dir__)
%w[config errors logging framing operation].each do |name|
  require File.join(root, 'runtime', name)
end
require File.join(root, 'runtime', 'dispatcher')
require File.join(root, 'runtime', 'server')
require File.join(root, 'core', 'units')

class M0Test < Minitest::Test
  def setup
    Sketchup.active_model = FakeModel.new(name: '', title: '', path: '', guid: 'abc',
                                          entities: [1, 2], active_entities: [1],
                                          selection: [], modified: false, attributes: {})
    probe = TCPServer.new('127.0.0.1', 0)
    port = probe.addr[1]
    probe.close
    @server = HomeCAD::Runtime::Server.new(port: port)
    @server.start
    @client = TCPSocket.new('127.0.0.1', port)
    @received = ''.b
  end

  def teardown
    @client&.close
    @server&.stop
  end

  def send_request(id, method, params = {})
    request = { 'jsonrpc' => '2.0', 'id' => id, 'method' => method, 'params' => params }
    @client.write(HomeCAD::Runtime::Framing.encode(JSON.generate(request)))
  end

  def next_response
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      @server.tick
      begin
        @received << @client.read_nonblock(4096)
      rescue IO::WaitReadable, EOFError
        nil
      end
      if @received.bytesize >= 4
        length = @received.byteslice(0, 4).unpack1('N')
        if @received.bytesize >= length + 4
          body = @received.slice!(0, length + 4).byteslice(4, length)
          return JSON.parse(body)
        end
      end
      raise 'response timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  def hello(protocol = 1, version = '0.1.0')
    send_request(1, 'hello', { 'protocol_version' => protocol, 'client_version' => version })
    next_response
  end

  def test_status_and_model_info
    response = hello
    assert_equal '0.1.0', response.dig('result', 'ruby_extension_version')
    assert_equal HomeCAD::Runtime::Dispatcher::CAPABILITIES, response.dig('result', 'capabilities')
    assert_includes response.dig('result', 'capabilities'), 'architecture.core.v1'
    send_request(2, 'homecad_status')
    status = next_response['result']
    assert_equal 'connected', status['connection_status']
    assert_equal '(Untitled)', status['model_name']
    assert_equal HomeCAD::Runtime::Dispatcher::CAPABILITIES, status['capabilities']
    @client.close
    @client = TCPSocket.new('127.0.0.1', @server.instance_variable_get(:@port))
    assert_equal 1, hello.dig('result', 'protocol_version')
    send_request(2, 'get_model_info')
    info = next_response['result']
    assert_equal 2, info['root_entity_count']
    assert_equal 1, info['active_entity_count']
    assert_nil info['path']
    assert_equal false, info['dev_fixture']
    assert_nil info['dev_fixture_id']
  end

  def test_model_info_reports_only_valid_dev_fixture_marker
    model = Sketchup.active_model
    model.attributes = { ['HomeCADDev', 'fixture_id'] => 'homecad-smoke-v1',
                         ['HomeCADDev', 'disposable'] => true }
    @client.close
    @client = TCPSocket.new('127.0.0.1', @server.instance_variable_get(:@port))
    hello
    send_request(2, 'get_model_info')
    info = next_response['result']
    assert_equal true, info['dev_fixture']
    assert_equal 'homecad-smoke-v1', info['dev_fixture_id']
    model.attributes[['HomeCADDev', 'disposable']] = false
    @client.close
    @client = TCPSocket.new('127.0.0.1', @server.instance_variable_get(:@port))
    hello
    send_request(2, 'get_model_info')
    ordinary = next_response['result']
    assert_equal false, ordinary['dev_fixture']
    assert_nil ordinary['dev_fixture_id']
  end

  def test_version_mismatch_and_pre_hello_rejection
    assert_equal 'incompatible_version', hello(2).dig('error', 'data', 'category')
    @client.close
    @client = TCPSocket.new('127.0.0.1', @server.instance_variable_get(:@port))
    send_request(4, 'get_model_info')
    assert_equal 'invalid_request', next_response.dig('error', 'data', 'category')
  end

  def test_unknown_method_after_hello
    hello
    send_request(2, 'eval_ruby')
    assert_equal -32601, next_response.dig('error', 'code')
  end

  def test_fragmented_frame_and_oversize_rejection
    bytes = HomeCAD::Runtime::Framing.encode(JSON.generate({ 'jsonrpc' => '2.0', 'id' => 1,
      'method' => 'hello', 'params' => { 'protocol_version' => 1, 'client_version' => '0.1.0' } }))
    @client.write(bytes.byteslice(0, 2))
    @server.tick
    @client.write(bytes.byteslice(2..))
    assert_equal 1, next_response.dig('result', 'protocol_version')
    @client.close
    @client = TCPSocket.new('127.0.0.1', @server.instance_variable_get(:@port))
    @client.write([HomeCAD::Runtime::Config::MAX_FRAME_BYTES + 1].pack('N'))
    assert_equal -32600, next_response.dig('error', 'code')
  end

  def test_units_and_operation_abort
    assert_in_delta 25.4, HomeCAD::Units.internal_to_mm(1), 0.00001
    assert_in_delta 1, HomeCAD::Units.mm_to_internal(25.4), 0.00001
    model = Object.new
    events = []
    model.define_singleton_method(:start_operation) { |*| events << :start; true }
    model.define_singleton_method(:commit_operation) { events << :commit }
    model.define_singleton_method(:abort_operation) { events << :abort }
    assert_raises(RuntimeError) do
      HomeCAD::Operation.run('test', model: model) { raise 'failed' }
    end
    assert_equal %i[start abort], events
    assert_equal :ok, HomeCAD::Operation.run('test', model: model) { :ok }
    assert_equal %i[start abort start commit], events
  end
end
