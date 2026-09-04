# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class AnalyticsEventsVisitorUuidTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :devices, :visitors

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # ── GET /events/:event_id (show) ────────────────────────────────────

  test 'event detail includes the visitor uuid resolved from PG' do
    visitor = visitors(:ios_visitor)
    row = { 'event_id' => 'abc123', 'visitor_id' => visitor.id, 'event_type' => 'open', 'properties' => {} }
    Analytics::EventsQueryService.stub(:find, row) do
      Clickhouse.stub(:read_enabled?, true) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/abc123", headers: @headers
      end
    end
    assert_response :ok
    data = JSON.parse(response.body)['data']
    assert_equal visitor.uuid, data['visitor_uuid']
    assert_equal visitor.id, data['resolved_visitor_id']
  end

  test 'event detail resolves a merged-away visitor to the survivor uuid via the identity map' do
    survivor = visitors(:ios_visitor)
    merged_id = 999_777 # deleted from PG by the merge
    row = { 'event_id' => 'abc125', 'visitor_id' => merged_id, 'event_type' => 'open', 'properties' => {} }
    Analytics::EventsQueryService.stub(:find, row) do
      resolve = ->(pid, ids) { ids.index_with { |vid| pid == @project.id && vid == merged_id ? survivor.id : vid } }
      ClickhouseIdentityMapService.stub(:resolve_many, resolve) do
        Clickhouse.stub(:read_enabled?, true) do
          get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/abc125", headers: @headers
        end
      end
    end
    assert_response :ok
    data = JSON.parse(response.body)['data']
    assert_equal survivor.uuid, data['visitor_uuid']
    assert_equal survivor.id, data['resolved_visitor_id']
  end

  test 'merged-visitor resolution stays project-scoped' do
    device = Device.create!(user_agent: 'x', ip: '10.1.1.1', remote_ip: '10.1.1.1',
                            platform: 'ios', vendor: "iso-#{SecureRandom.hex(4)}")
    foreign = Visitor.create!(project: projects(:two), device: device, uuid: SecureRandom.uuid)
    row = { 'event_id' => 'abc126', 'visitor_id' => 999_778, 'event_type' => 'open', 'properties' => {} }
    Analytics::EventsQueryService.stub(:find, row) do
      ClickhouseIdentityMapService.stub(:resolve_many, ->(_pid, ids) { ids.index_with { foreign.id } }) do
        Clickhouse.stub(:read_enabled?, true) do
          get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/abc126", headers: @headers
        end
      end
    end
    assert_response :ok
    data = JSON.parse(response.body)['data']
    assert_nil data['visitor_uuid'], 'survivor from another project must not leak'
    assert_nil data['resolved_visitor_id'], 'foreign survivor id must not leak either'
  end

  test 'event detail returns null visitor_uuid for visitor_id 0' do
    row = { 'event_id' => 'abc124', 'visitor_id' => 0, 'event_type' => 'open', 'properties' => {} }
    Analytics::EventsQueryService.stub(:find, row) do
      Clickhouse.stub(:read_enabled?, true) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/abc124", headers: @headers
      end
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert body['data'].key?('visitor_uuid')
    assert_nil body['data']['visitor_uuid']
    assert_nil body['data']['resolved_visitor_id']
  end

  # ── GET /events (index) — batched row annotation ────────────────────

  test 'index: annotates rows with visitor_uuid and resolved_visitor_id from PG' do
    visitor = visitors(:ios_visitor)
    rows = [
      { 'event_id' => 'e1', 'visitor_id' => visitor.id },
      { 'event_id' => 'e2', 'visitor_id' => visitor.id },
      { 'event_id' => 'e3', 'visitor_id' => 0 }
    ]

    with_list_stub(rows) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", headers: @headers
    end

    assert_response :ok
    data = JSON.parse(response.body)['data']
    assert_equal [visitor.uuid, visitor.uuid, nil], data.map { |r| r['visitor_uuid'] }
    assert_equal [visitor.id, visitor.id, nil], data.map { |r| r['resolved_visitor_id'] }
  end

  test 'index: resolves merged-away visitors through ONE batched identity-map call' do
    survivor = visitors(:ios_visitor)
    merged_id = 999_777
    rows = [
      { 'event_id' => 'e1', 'visitor_id' => merged_id },
      { 'event_id' => 'e2', 'visitor_id' => merged_id },
      { 'event_id' => 'e3', 'visitor_id' => survivor.id }
    ]
    calls = []
    fake_map = lambda { |pid, ids|
      calls << [pid, ids.sort]
      { merged_id => survivor.id }
    }

    with_list_stub(rows) do
      ClickhouseIdentityMapService.stub(:resolve_many, fake_map) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", headers: @headers
      end
    end

    assert_response :ok
    data = JSON.parse(response.body)['data']
    assert_equal [survivor.uuid] * 3, data.map { |r| r['visitor_uuid'] }
    assert_equal [survivor.id] * 3, data.map { |r| r['resolved_visitor_id'] }
    assert_equal [[@project.id, [merged_id]]], calls, 'PG misses must resolve in a single batched call'
  end

  private

  def with_list_stub(rows, &block)
    result = { data: rows, next_cursor: nil, total_count: rows.size }
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::EventsQueryService.stub(:list, result, &block)
    end
  end
end
