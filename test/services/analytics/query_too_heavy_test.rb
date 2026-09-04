# frozen_string_literal: true

require 'test_helper'

class AnalyticsQueryTooHeavyTest < ActiveSupport::TestCase
  test 'is a StandardError carrying a message' do
    e = Analytics::QueryTooHeavy.new('boom')
    assert_kind_of StandardError, e
    assert_equal 'boom', e.message
  end
end
