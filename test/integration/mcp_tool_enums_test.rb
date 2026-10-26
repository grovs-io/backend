require "test_helper"

# The MCP server builds its tool schemas from mcp/src/backend-enums.json; this keeps that file in step.
class McpToolEnumsTest < ActiveSupport::TestCase
  ENUMS_PATH = Rails.root.join("../../mcp/src/backend-enums.json")

  def expected
    {
      "metrics" => Analytics::MetricQuery::METRICS,
      "dimensions" => Analytics::MetricQuery::DIMENSIONS,
      "granularities" => Analytics::TimeBuckets::GRANULARITIES,
      "max_limit" => Analytics::MetricQuery::MAX_LIMIT,
      "breakdown_dimensions" => (Segments::Breakdown::DIMENSIONS if defined?(Segments::Breakdown)),
      "identity_fields" => McpIdentityPolicy::IDENTITY_FIELDS,
      "identity_property_core" => McpIdentityPolicy::IDENTITY_PROPERTY_CORE,
      "event_filter_operators" => DashboardWidget::FILTER_OPERATORS,
      "report_max_days" => (InAppReport::MAX_DAYS if defined?(InAppReport))
    }.compact
  end

  test "the MCP server's enums match the backend" do
    skip "mcp repo not checked out next to the backend" unless ENUMS_PATH.exist?

    actual = JSON.parse(ENUMS_PATH.read)
    actual.delete("breakdown_dimensions") unless defined?(Segments::Breakdown)
    actual.delete("report_max_days") unless defined?(InAppReport)
    assert_equal expected, actual, "update #{ENUMS_PATH} to match the backend"
  end
end
