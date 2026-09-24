require 'minitest/autorun'

module HomeCAD
  VERSION = '0.1.0'
  PROTOCOL_VERSION = 1
  module Runtime
    class BridgeError < StandardError
      attr_reader :category
      def initialize(_code, category, message)
        super(message)
        @category = category
      end
    end
  end
end
module Sketchup
  class << self
    attr_accessor :actions, :accepted
    def send_action(action)
      self.actions ||= []
      actions << action
      accepted
    end
  end
end
require File.expand_path('../../sketchup/homecad/runtime/dispatcher', __dir__)

class UndoTest < Minitest::Test
  def setup
    Sketchup.actions = []
    Sketchup.accepted = true
  end

  def test_exactly_one_native_action
    assert_equal({ 'status' => 'queued', 'actions' => 1, 'operation' => 'undo' },
                 HomeCAD::Runtime::Dispatcher.undo(Object.new, {}))
    assert_equal ['editUndo:'], Sketchup.actions
  end

  def test_unavailable_and_invalid_params
    Sketchup.accepted = false
    assert_equal 'undo_unavailable', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Runtime::Dispatcher.undo(Object.new, {})
    }.category
    assert_equal ['editUndo:'], Sketchup.actions
    assert_equal 'invalid_request', assert_raises(HomeCAD::Runtime::BridgeError) {
      HomeCAD::Runtime::Dispatcher.undo(Object.new, { 'count' => 2 })
    }.category
    assert_equal ['editUndo:'], Sketchup.actions
  end
end
