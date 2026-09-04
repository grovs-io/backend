# frozen_string_literal: true

require 'test_helper'
require_relative '../../../test/integration/auth_test_helper'

class PurchasesRetentionTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :stripe_subscriptions, :stripe_payment_intents

  ROUTE = 'purchases/revenue'

  setup do
    @free_instance = instances(:two)
    @free_instance.update!(cold_storage_days: 365, delete_days: 730)
    @free_project = projects(:two)
    @free_user = users(:super_admin_user)
  end

  test 'revenue metrics past the hot window are rejected for a free project' do
    post_revenue(start_date: (Date.current - 400).to_s)

    assert_response :unprocessable_entity
    assert_equal 'retention_window_exceeded', JSON.parse(response.body)['error_code']
  end

  test 'revenue metrics inside the hot window are allowed' do
    post_revenue(start_date: (Date.current - 100).to_s)

    assert_not_equal 'retention_window_exceeded', error_code
  end

  # RevenueLedgerQuery is pure Postgres, so the ledger flag alone must not limit retention.
  test 'the ledger read flag alone does not enforce retention' do
    Clickhouse.stub(:analytics_rollups_read_enabled?, false) do
      RevenueLedger.stub(:reads_enabled?, true) do
        post "#{API_PREFIX}/projects/#{@free_project.id}/#{ROUTE}",
             params: { start_date: (Date.current - 400).to_s, end_date: Date.current.to_s },
             headers: doorkeeper_headers_for(@free_user)
      end
    end

    assert_not_equal 'retention_window_exceeded', error_code
  end

  test 'the rollup read flag off leaves revenue ungated' do
    Clickhouse.stub(:analytics_rollups_read_enabled?, false) do
      RevenueLedger.stub(:reads_enabled?, false) do
        post "#{API_PREFIX}/projects/#{@free_project.id}/#{ROUTE}",
             params: { start_date: (Date.current - 400).to_s, end_date: Date.current.to_s },
             headers: doorkeeper_headers_for(@free_user)
      end
    end

    assert_not_equal 'retention_window_exceeded', error_code
  end

  private

  def post_revenue(params)
    Clickhouse.stub(:analytics_rollups_read_enabled?, true) do
      post "#{API_PREFIX}/projects/#{@free_project.id}/#{ROUTE}",
           params: params.merge(end_date: Date.current.to_s),
           headers: doorkeeper_headers_for(@free_user)
    end
  end

  def error_code
    JSON.parse(response.body)['error_code']
  rescue JSON::ParserError
    nil
  end
end
