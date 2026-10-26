# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class AnalyticsEventsExplorerSegmentFilterTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @project = projects(:one)
    @headers = doorkeeper_headers_for(users(:admin_user))
  end

  def capture_visitor_clause(segment_id:)
    captured = nil
    fake = lambda { |*args, **kw|
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: 0 }
    }

    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::EventsQueryService.stub(:list, fake) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", params: { segment_id: segment_id }, headers: @headers
      end
    end
    captured
  end

  test 'index: segment_id is ignored without the enterprise tree' do
    skip 'enterprise tree present' if defined?(Segments)
    captured = capture_visitor_clause(segment_id: 'anything')
    assert_response :ok
    assert_nil captured[1][:visitor_clause]
  end

  test 'index: a blank segment_id forwards visitor_clause: nil in both editions' do
    captured = capture_visitor_clause(segment_id: '')
    assert_response :ok
    assert_nil captured[1][:visitor_clause]
  end
end
