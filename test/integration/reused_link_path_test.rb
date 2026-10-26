# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'mcp_auth_test_helper'

class ReusedLinkPathTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include McpAuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :applications, :ios_configurations,
           :android_configurations, :domains, :redirect_configs, :devices, :visitors, :links, :campaigns

  PATH = 'reused-path'

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    @dashboard_headers = doorkeeper_headers_for(users(:admin_user))
    @mcp_headers = create_mcp_headers_for(users(:admin_user))
    @admin_api_key = 'test-admin-api-key'
    ENV['ADMIN_API_KEY'] = @admin_api_key
    @flags = %i[clickhouse_write_enabled clickhouse_read_enabled clickhouse_analytics_rollups_read_enabled]
               .index_with { |f| Rails.application.config.public_send(f) }
    clear_event_queue!
  end

  teardown do
    ENV.delete('ADMIN_API_KEY')
    @flags.each { |f, v| Rails.application.config.public_send("#{f}=", v) }
    clear_event_queue!
  end

  %i[postgres clickhouse].each do |store|
    test "#{store}: delete then recreate at the same path moves every endpoint to the new link" do
      use_store(store)
      old = create_link
      send_view(:ios)
      process_events!(store)
      assert_all_endpoints(old, views: 1, store: store) # also warms the Redis lookup cache

      delete_link(old)
      new = create_link
      assert_not_equal old.id, new.id
      send_view(:android)
      views_by_link = process_events!(store)

      assert_equal({ old.id => 1, new.id => 1 }, views_by_link, 'each view lands on the link live at the time')
      assert_all_endpoints(new, views: 1, store: store)
    end

    test "#{store}: a path reused twice resolves to the only active link" do
      use_store(store)
      first = create_link
      send_view(:ios)
      process_events!(store)
      delete_link(first)

      second = create_link
      send_view(:android)
      process_events!(store)
      delete_link(second)

      third = create_link
      send_view(:ios)
      send_view(:android)
      process_events!(store)

      assert_all_endpoints(third, views: 2, store: store)
    end

    test "#{store}: a deleted link with no replacement keeps reporting its own history" do
      use_store(store)
      old = create_link
      send_view(:ios)
      process_events!(store)
      delete_link(old)

      assert_equal old.id, server_sdk_link['id']
      assert_equal false, server_sdk_link['active']
      assert_equal old.id, server_sdk_metrics['id']
      assert_equal 1, server_sdk_metrics['total_views']
      assert_equal old.id, sdk_link['id']
      assert_equal({ old.id.to_s => 1 }, mcp_views)

      # Automation always counts active links only, so a deleted one has the link but no metrics.
      link, metrics = automation_details
      assert_equal old.id, link['id']
      assert_nil metrics
    end

    # Archive deactivates links with update_all (no callbacks), so it must clear the cached lookup itself.
    test "#{store}: archiving the campaign moves every endpoint to the inactive link at once" do
      use_store(store)
      link = create_link(campaign_id: campaigns(:one).id)
      send_view(:ios)
      process_events!(store)
      assert_all_endpoints(link, views: 1, store: store) # warms the Redis lookup cache

      delete "#{API_PREFIX}/projects/#{@project.id}/campaigns/#{campaigns(:one).id}", headers: @dashboard_headers
      assert_response :ok
      assert_not link.reload.active
      assert_archived_endpoints(link, views: 1)

      send_view(:android)
      assert_equal({ link.id => 2 }, process_events!(store), 'a view on an archived link still lands on it')
      assert_archived_endpoints(link, views: 2)
    end

    test "#{store}: another project's active link at the same path never leaks in" do
      use_store(store)
      ours = create_link
      send_view(:ios)
      process_events!(store)
      delete_link(ours)
      Link.create!(domain: domains(:two), redirect_config: ours.redirect_config, path: PATH,
                   title: 'Other project', generated_from_platform: 'ios', active: true)

      assert_equal ours.id, server_sdk_link['id']
      assert_equal ours.id, server_sdk_metrics['id']
      assert_equal ours.id, sdk_link['id']
      assert_equal ours.id, automation_details[0]['id']
      assert_equal({ ours.id.to_s => 1 }, mcp_views)
    end
  end

  test 'an unknown path is still not found on every endpoint' do
    get "#{SDK_PREFIX}/link/#{PATH}", headers: server_sdk_headers
    assert_response :not_found
    get "#{SDK_PREFIX}/metrics_for_link/#{PATH}", headers: server_sdk_headers
    assert_response :not_found
    assert_nil sdk_link
    assert_equal [nil, nil], automation_details
    post "#{MCP_PREFIX}/analytics/link", params: mcp_params, headers: @mcp_headers
    assert_response :not_found
  end

  private

  def use_store(store)
    on = store == :clickhouse
    skip_unless_clickhouse! if on
    @flags.each_key { |f| Rails.application.config.public_send("#{f}=", on) }
  end

  def create_link(**extra)
    post "#{API_PREFIX}/projects/#{@project.id}/links", params: { title: 'Reused', path: PATH, **extra },
                                                         headers: @dashboard_headers
    assert_response :ok
    Link.where(domain: @project.domain, path: PATH, active: true).sole
  end

  def delete_link(link)
    delete "#{API_PREFIX}/projects/#{@project.id}/links/#{link.id}", headers: @dashboard_headers
    assert_response :ok
    assert_not link.reload.active
  end

  def send_view(platform)
    visitor = platform == :ios ? visitors(:ios_visitor) : visitors(:android_visitor)
    post "#{SDK_PREFIX}/event", params: { event: Grovs::Events::VIEW, path: PATH },
                                headers: sdk_headers_for(@project, visitor, platform: platform.to_s)
    assert_response :ok
  end

  def process_events!(store)
    raw = REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
    job = BatchEventProcessorJob.new
    job.jid = "reused-path-#{SecureRandom.hex(4)}"
    job.send(:process_batch, raw)
    clear_event_queue! # the view dedup window would swallow the next batch's views

    if store == :clickhouse
      partition = Date.current.strftime('%Y%m')
      ClickhouseRollupRebuildService.rebuild_partition_range(partition, partition)
      tally = ch_select_events(@project.id).select { |e| e['event_type'] == Grovs::Events::VIEW }
                                           .map { |e| e['link_id'] }.tally
      # Only ClickHouse can answer from here on; otherwise this would test Postgres twice.
      LinkDailyStatistic.where(project_id: @project.id).delete_all
      Event.where(project_id: @project.id).delete_all
      tally
    else
      Event.where(project_id: @project.id, event: Grovs::Events::VIEW, created_at: Date.current.all_day)
           .group(:link_id).count
    end
  end

  def clear_event_queue!
    REDIS.with do |c|
      keys = c.keys("#{BatchEventProcessorJob::DEDUP_PREFIX}:*") +
             c.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*") +
             c.keys("#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:reused-path-*") +
             c.keys("#{BatchEventProcessorJob::HEARTBEAT_PREFIX}:reused-path-*")
      c.del(BatchEventProcessorJob::REDIS_KEY, *keys)
    end
  end

  def assert_all_endpoints(link, views:, store:)
    msg = "#{store}: every endpoint must resolve #{PATH} to link #{link.id}"
    assert_equal link.id, server_sdk_link['id'], msg
    metrics = server_sdk_metrics
    assert_equal [link.id, views], [metrics['id'], metrics['total_views']], msg
    assert_equal link.id, sdk_link['id'], msg
    found, found_metrics = automation_details
    assert_equal [link.id, link.id, views], [found['id'], found_metrics['id'], found_metrics['total_views']], msg
    assert_equal({ link.id.to_s => views }, mcp_views, msg)
  end

  def assert_archived_endpoints(link, views:)
    found = server_sdk_link
    assert_equal [link.id, false], [found['id'], found['active']]
    metrics = server_sdk_metrics
    assert_equal [link.id, views], [metrics&.dig('id'), metrics&.dig('total_views')], 'Server SDK metrics must survive archive'
    assert_equal [link.id, false], sdk_link.values_at('id', 'active')
    found, found_metrics = automation_details
    assert_equal [link.id, false], found.values_at('id', 'active')
    assert_nil found_metrics # automation counts active links only
    assert_equal({ link.id.to_s => views }, mcp_views)
  end

  def server_sdk_link
    get "#{SDK_PREFIX}/link/#{PATH}", headers: server_sdk_headers
    assert_response :ok
    JSON.parse(response.body)['link']
  end

  def server_sdk_metrics
    get "#{SDK_PREFIX}/metrics_for_link/#{PATH}", headers: server_sdk_headers
    assert_response :ok
    JSON.parse(response.body)['metrics']
  end

  def sdk_link
    post "#{SDK_PREFIX}/link_details", params: { path: PATH },
                                       headers: sdk_headers_for(@project, visitors(:ios_visitor), platform: 'ios')
    assert_response :ok
    JSON.parse(response.body)
  end

  def automation_details
    post "#{API_PREFIX}/automation/details_for_link",
         params: { key: @instance.api_key, path: PATH, test: false }.to_json,
         headers: api_headers.merge('X-AUTH' => @admin_api_key, 'Content-Type' => 'application/json')
    assert_response :ok
    JSON.parse(response.body).values_at('link', 'metrics')
  end

  def mcp_views
    post "#{MCP_PREFIX}/analytics/link", params: mcp_params, headers: @mcp_headers
    assert_response :ok
    JSON.parse(response.body)['metrics'].transform_values { |m| m['view'] }
  end

  def mcp_params
    { project_id: @project.hashid, path: PATH, start_date: Date.current.to_s, end_date: Date.current.to_s }
  end

  def server_sdk_headers
    { 'PROJECT-KEY' => @instance.api_key, 'ENVIRONMENT' => 'production', 'Host' => sdk_host }
  end
end
