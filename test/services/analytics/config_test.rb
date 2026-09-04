# frozen_string_literal: true

require 'test_helper'

class AnalyticsConfigTest < ActiveSupport::TestCase
  test 'defaults' do
    assert_equal 25, Analytics::Config::QUERY_MAX_EXECUTION_SEC
    assert_equal 4_000_000_000, Analytics::Config::QUERY_MAX_MEMORY_BYTES
    assert_equal 64, Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
  end
end
