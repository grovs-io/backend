# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

# visitor_details derives its start_date, so retention clamps the range instead of rejecting.
class AnalyticsRetentionVisitorClampTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :devices, :visitors, :links, :purchase_events,
           :stripe_subscriptions, :stripe_payment_intents

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @instance.update!(cold_storage_days: 30, delete_days: 30)
    @visitor = visitors(:ios_visitor)
    @visitor.update!(created_at: 3.years.ago)
    @headers = doorkeeper_headers_for(users(:admin_user))
  end

  test 'an ancient visitor still opens, with the range clamped to the cutoff' do
    captured = capture_query_start_dates { get_details }

    assert_response :success
    assert_equal [Date.current - 30, Date.current - 30], captured
  end

  test 'the response reports the range the totals actually cover' do
    capture_query_start_dates { get_details }

    assert_equal (Date.current - 30).to_s, JSON.parse(response.body)['metrics_since']
  end

  test 'an unclamped visitor reports its own first-seen date' do
    @visitor.update!(created_at: 10.days.ago)
    capture_query_start_dates { get_details }

    assert_equal 10.days.ago.to_date.to_s, JSON.parse(response.body)['metrics_since']
  end

  test 'a recent visitor keeps its own first-seen date' do
    @visitor.update!(created_at: 10.days.ago)

    captured = capture_query_start_dates { get_details }

    assert_response :success
    assert_equal [10.days.ago.to_date, 10.days.ago.to_date], captured
  end

  test 'the clamp is inert when ClickHouse is not the analytics read source' do
    captured = capture_query_start_dates(clickhouse: false) { get_details }

    assert_response :success
    assert_equal [3.years.ago.to_date, 3.years.ago.to_date], captured
  end

  private

  def get_details
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{@visitor.id}", headers: @headers
  end

  def capture_query_start_dates(clickhouse: true, &block)
    captured = []
    recorder = lambda do |params:, project:|
      _ = project
      captured << params[:start_date]
      FakeQuery.new
    end

    Clickhouse.stub(:analytics_rollups_read_enabled?, clickhouse) do
      RevenueLedger.stub(:reads_enabled?, false) do
        VisitorStatisticsQuery.stub(:new, recorder) do
          VisitorReferralStatisticsQuery.stub(:new, recorder, &block)
        end
      end
    end

    captured
  end

  class FakeQuery
    def call = { visitors: [] }
  end
end
