# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

# Automation and Server SDK metrics query from the Unix epoch, so retention clamps them.
class AnalyticsRetentionEpochClampTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :devices, :visitors, :links, :purchase_events,
           :stripe_subscriptions, :stripe_payment_intents

  setup do
    @instance = instances(:one)
    @instance.update!(cold_storage_days: 365, delete_days: 365)
    @project = projects(:one)
    @admin_api_key = 'test-admin-api-key'
    ENV['ADMIN_API_KEY'] = @admin_api_key
  end

  teardown { ENV.delete('ADMIN_API_KEY') }

  test 'automation metrics_for_user clamps the epoch start to the cutoff' do
    captured = capture_start_dates { automation_request }

    assert captured.any?, 'the query object was never reached'
    assert_equal [cutoff] * captured.size, captured
  end

  test 'automation metrics_for_user keeps the epoch when ClickHouse is not the source' do
    captured = capture_start_dates(clickhouse: false) { automation_request }

    assert_equal [Time.at(0).to_date] * captured.size, captured
  end

  test 'server SDK metrics_for_project clamps the epoch start to the cutoff' do
    captured = capture_link_start_dates { server_sdk_request }

    assert captured.any?, 'the query object was never reached'
    assert_equal [cutoff], captured
  end

  test 'server SDK metrics_for_link clamps the epoch start to the cutoff' do
    captured = capture_link_start_dates { server_sdk_link_request }

    assert captured.any?, 'the query object was never reached'
    assert_equal [cutoff], captured
  end

  test 'automation details_for_link clamps the epoch start to the cutoff' do
    captured = capture_link_start_dates { automation_link_request }

    assert captured.any?, 'the query object was never reached'
    assert_equal [cutoff], captured
  end

  test 'automation details_for_link keeps the epoch when ClickHouse is not the source' do
    captured = capture_link_start_dates(clickhouse: false) { automation_link_request }

    assert_equal [Time.at(0).to_date], captured
  end

  private

  def cutoff
    @cutoff ||= Date.current - @instance.cold_storage_days
  end

  def automation_request
    post "#{API_PREFIX}/automation/metrics_for_user",
         params: { key: @instance.api_key, vendor_id: devices(:ios_device).vendor, test: false }.to_json,
         headers: api_headers.merge('X-AUTH' => @admin_api_key, 'Content-Type' => 'application/json')
  end

  def server_sdk_request
    get "#{SDK_PREFIX}/metrics_for_project",
        headers: { 'PROJECT-KEY' => @instance.api_key, 'ENVIRONMENT' => 'production', 'Host' => sdk_host }
  end

  def capture_start_dates(clickhouse: true, &block)
    captured = []
    recorder = lambda do |params:, project:|
      _ = project
      captured << params[:start_date]
      FakeQuery.new(:visitors, [{}])
    end

    with_clickhouse(clickhouse) do
      VisitorStatisticsQuery.stub(:new, recorder) do
        VisitorReferralStatisticsQuery.stub(:new, recorder, &block)
      end
    end

    captured
  end

  def server_sdk_link_request
    get "#{SDK_PREFIX}/metrics_for_link/#{links(:basic_link).path}",
        headers: { 'PROJECT-KEY' => @instance.api_key, 'ENVIRONMENT' => 'production', 'Host' => sdk_host }
  end

  def automation_link_request
    post "#{API_PREFIX}/automation/details_for_link",
         params: { key: @instance.api_key, path: links(:basic_link).path, test: false }.to_json,
         headers: api_headers.merge('X-AUTH' => @admin_api_key, 'Content-Type' => 'application/json')
  end

  def capture_link_start_dates(clickhouse: true, &block)
    captured = []
    recorder = lambda do |params:, project:, **_rest|
      _ = project
      captured << params[:start_date]
      FakeQuery.new(:links, [])
    end

    with_clickhouse(clickhouse) { LinkStatisticsQuery.stub(:new, recorder, &block) }
    captured
  end

  def with_clickhouse(enabled, &block)
    Clickhouse.stub(:analytics_rollups_read_enabled?, enabled) do
      RevenueLedger.stub(:reads_enabled?, false, &block)
    end
  end

  class FakeQuery
    def initialize(key, rows)
      @key = key
      @rows = rows
    end

    def call = { @key => @rows }
  end
end
