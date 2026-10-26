# frozen_string_literal: true

require "test_helper"

class ClickhouseJsonOutputTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup { skip_unless_clickhouse! }

  test "configured connections preserve native JSON numbers and numeric strings" do
    assert_json_types(Clickhouse.connection)
  end

  test "one-off connections preserve native JSON numbers without test connection settings" do
    assert_json_types(Clickhouse.build_connection(database: "default"))
  end

  private

  def assert_json_types(connection)
    row = connection.select_one(<<~SQL)
      SELECT CAST('{"count":2,"label":"2","active":true,"nested":{"count":3}}' AS JSON) AS properties
    SQL

    assert_equal({ "count" => 2, "label" => "2", "active" => true, "nested" => { "count" => 3 } },
                 row.fetch("properties"))
  end
end
