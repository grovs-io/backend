# frozen_string_literal: true

require 'test_helper'
require_relative '../mcp_auth_test_helper'

class McpAnalyticsRetentionTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :links,
           :stripe_subscriptions, :stripe_payment_intents

  setup do
    @free_instance = instances(:two)
    @free_instance.update!(cold_storage_days: 365, delete_days: 730)
    @free_project = projects(:two)
    @free_link = links(:second_link)
    @free_headers = create_mcp_headers_for(users(:super_admin_user))
  end

  ROUTES = %w[analytics/overview analytics/top_links analytics/link links/search campaigns/search].freeze

  ROUTES.each do |route|
    test "#{route} rejects a free project reaching past the hot window" do
      post_mcp(route, (Date.current - 400).to_s)

      assert_response :unprocessable_entity
      assert_equal 'retention_window_exceeded', json_response['error_code']
    end

    test "#{route} allows a free project inside the hot window" do
      post_mcp(route, (Date.current - 100).to_s)

      assert_response :success
    end
  end

  private

  # Only analytics/link accepts a path — every other request contract rejects it.
  def post_mcp(route, start_date)
    params = { project_id: @free_project.hashid, start_date: start_date, end_date: Date.current.to_s }
    params[:path] = @free_link.path if route == 'analytics/link'

    Clickhouse.stub(:analytics_rollups_read_enabled?, true) do
      post "#{MCP_PREFIX}/#{route}", params: params, headers: @free_headers
    end
  end
end
