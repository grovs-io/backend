require "test_helper"

class McpInstanceStatusSerializerTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @instance = instances(:one)
    Project.find_or_create_by!(instance: @instance, test: true) do |p|
      p.name = "MCP Test Project"
      p.identifier = "mcp-test-#{SecureRandom.hex(4)}"
    end
    @instance.reload
  end

  test "usage degrades to nil current_mau when the CH MAU read fails in primary mode" do
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true

    ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { nil }) do
      usage = McpInstanceStatusSerializer.usage_for(@instance)
      assert_nil usage[:current_mau], "a CH outage must degrade MCP usage, not 500 /mcp/status"
      assert_equal Grovs.free_mau_count, usage[:mau_limit]
    end
  ensure
    Rails.application.config.clickhouse_primary = prev
  end

  test "usage serves the CH MAU in primary mode" do
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true

    ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { 7 }) do
      usage = McpInstanceStatusSerializer.usage_for(@instance)
      assert_equal 7, usage[:current_mau]
    end
  ensure
    Rails.application.config.clickhouse_primary = prev
  end
end
