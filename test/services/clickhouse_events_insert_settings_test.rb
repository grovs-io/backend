require "test_helper"

class ClickhouseEventsInsertSettingsTest < ActiveSupport::TestCase
  FakeConnection = Struct.new(:calls) do
    def insert(table, _rows, settings: {})
      calls << [table, settings]
    end
  end

  def capture_inserts(&inserts)
    fake = FakeConnection.new([])
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(fake) }, &inserts)
    end
    fake.calls
  end

  test "an events insert survives an outbox view failure; other tables keep default settings" do
    calls = capture_inserts do
      ClickhouseWriteService.insert_canonical_events([{ project_id: 1, event_type: "install", event_id: "a", created_at: Time.current }])
      ClickhouseWriteService.insert_purchase_events([{ project_id: 1, event_type: "buy", transaction_id: "t1", created_at: Time.current }])
    end

    assert_equal({ materialized_views_ignore_errors: 1 }, calls.find { |table, _| table == "events" }.last)
    assert_empty calls.find { |table, _| table == "purchase_events" }.last
  end
end
