# frozen_string_literal: true

require "test_helper"

# Phase 2: canonical deduped store + durable delivery (bounded retry -> DLQ).
class ClickhouseCanonicalWriteTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  DLQ_KEY = ClickhouseWriteService::CANONICAL_DLQ_KEY

  setup do
    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    REDIS.with { |c| c.del(DLQ_KEY) }
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.with { |c| c.del(DLQ_KEY) }
  end

  def sample_row(event_id:, project_id: 4242)
    {
      event_id: event_id,
      project_id: project_id,
      event_type: Grovs::Events::OPEN,
      created_at: Time.current
    }
  end

  # --- canonical dedup (CH-gated) ---

  test "duplicate delivery of the same batch collapses in canonical" do
    skip_unless_clickhouse!
    pid = 778_801
    rows = [sample_row(event_id: "dup-a", project_id: pid), sample_row(event_id: "dup-b", project_id: pid)]

    assert ClickhouseWriteService.insert_canonical_events(rows)
    assert ClickhouseWriteService.insert_canonical_events(rows) # replayed batch

    deduped = Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{pid}")
    end
    assert_equal 2, deduped, "duplicate delivery must not inflate canonical counts"
  end

  test "same-ms same-name custom events with different properties both survive FINAL" do
    skip_unless_clickhouse!
    pid = 778_803
    base = { project_id: pid, device_id: 100, event_type: Grovs::Events::CUSTOM,
             event_name: "batch_step", session_id: "same-ms", created_at: Time.current }
    rows = [
      base.merge(properties: { "step" => "1" }),
      base.merge(properties: { "step" => "2" })
    ]

    assert ClickhouseWriteService.insert_canonical_events(rows)

    kept = Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{pid}")
    end
    assert_equal 2, kept, "different-properties events in the same ms must not collapse"
  end

  test "canonical rows carry ingested_at" do
    skip_unless_clickhouse!
    pid = 778_802
    assert ClickhouseWriteService.insert_canonical_events([sample_row(event_id: "ts-1", project_id: pid)])

    ingested = Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM events WHERE project_id = #{pid} AND ingested_at > toDateTime64('1970-01-01 00:00:00', 3)")
    end
    assert_equal 1, ingested, "ingested_at must be stamped at insert time"
  end

  # --- bounded retry -> DLQ (CH-free unit tests) ---

  test "transient failure retries then succeeds within bound, no DLQ" do
    rows = [sample_row(event_id: "retry-1")]
    attempts = 0
    stub = lambda do |_table, _rows|
      attempts += 1
      raise StandardError, "transient" if attempts < 2

      true
    end

    ClickhouseWriteService.stub(:raw_insert, stub) do
      assert ClickhouseWriteService.deliver_canonical(rows)
    end

    assert_equal 2, attempts, "should retry once then succeed"
    assert_equal 0, REDIS.with { |c| c.llen(DLQ_KEY) }, "successful delivery must not write DLQ"
  end

  test "poison batch routes to DLQ after bounded retries, does not loop forever" do
    rows = [sample_row(event_id: "poison-1"), sample_row(event_id: "poison-2")]
    attempts = 0
    stub = lambda do |_table, _rows|
      attempts += 1
      raise StandardError, "always fails"
    end

    ClickhouseWriteService.stub(:raw_insert, stub) do
      assert_not ClickhouseWriteService.deliver_canonical(rows)
    end

    assert_equal ClickhouseWriteService::CANONICAL_MAX_ATTEMPTS, attempts,
                 "must stop after a bounded number of attempts (no infinite repush)"
    assert_equal 1, REDIS.with { |c| c.llen(DLQ_KEY) }, "poison batch must land in DLQ exactly once"

    entry = JSON.parse(REDIS.with { |c| c.lindex(DLQ_KEY, 0) })
    assert_equal 2, entry["rows"].size, "DLQ entry must preserve the failed rows for replay"
  end

  test "when ClickHouse is primary the canonical write fails fast in a single attempt" do
    rows = [sample_row(event_id: "fast-1")]
    attempts = 0
    stub = lambda do |_table, _rows|
      attempts += 1
      raise StandardError, "brownout"
    end

    Clickhouse.stub(:primary?, true) do
      ClickhouseWriteService.stub(:raw_insert, stub) do
        assert_not ClickhouseWriteService.deliver_canonical(rows)
      end
    end

    assert_equal ClickhouseWriteService::CANONICAL_PRIMARY_MAX_ATTEMPTS, attempts,
                 "primary mode must not block the batch worker with multiple retries"
    assert_equal 1, attempts
  end

  test "when ClickHouse is not primary the canonical write keeps the full bounded retry" do
    rows = [sample_row(event_id: "slow-1")]
    attempts = 0
    stub = lambda { |_table, _rows| 
      attempts += 1
      raise StandardError, "down"
    }

    Clickhouse.stub(:primary?, false) do
      ClickhouseWriteService.stub(:raw_insert, stub) do
        assert_not ClickhouseWriteService.deliver_canonical(rows)
      end
    end

    assert_equal ClickhouseWriteService::CANONICAL_MAX_ATTEMPTS, attempts
  end

  test "ch down buffers to dlq then drains with no loss and no storm" do
    skip_unless_clickhouse!
    pid = 778_803
    rows = [sample_row(event_id: "drain-a", project_id: pid), sample_row(event_id: "drain-b", project_id: pid)]

    # CH "down": deliver_canonical exhausts bounded retries and parks in DLQ.
    attempts = 0
    down = lambda do |_table, _rows|
      attempts += 1
      raise StandardError, "CH down"
    end
    ClickhouseWriteService.stub(:raw_insert, down) do
      assert_not ClickhouseWriteService.deliver_canonical(rows)
    end
    assert_equal ClickhouseWriteService::CANONICAL_MAX_ATTEMPTS, attempts, "bounded retry — no storm"
    assert_equal 1, REDIS.with { |c| c.llen(DLQ_KEY) }, "batch buffered in DLQ"

    # No CH rows yet (it was down).
    pre = Clickhouse.with { |conn| conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{pid}") }
    assert_equal 0, pre

    # CH back up: drain replays the buffered batch — no loss.
    drained = ClickhouseWriteService.drain_canonical_dlq
    assert_equal 1, drained
    assert_equal 0, REDIS.with { |c| c.llen(DLQ_KEY) }, "DLQ empty after drain"

    post = Clickhouse.with { |conn| conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{pid}") }
    assert_equal 2, post, "drained rows land in canonical with no loss"
  end

  test "backpressure metric emitted on every delivery attempt set" do
    rows = [sample_row(event_id: "metric-1")]
    captured = []
    metric_stub = lambda do |name, value, tags: {}|
      captured << [name, value, tags]
    end

    Grovs::Metrics.stub(:histogram, metric_stub) do
      ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { true }) do
        assert ClickhouseWriteService.deliver_canonical(rows)
      end
    end

    lag = captured.find { |name, _, _| name == "clickhouse.canonical.delivery_ms" }
    assert lag, "must emit a delivery latency (backpressure) metric"
  end

  # --- HIGH-2: heartbeat hook isolation ---

  test "a raising before_attempt hook does not abort delivery" do
    rows = [sample_row(event_id: "hb-raise-1")]
    ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { true }) do
      assert ClickhouseWriteService.deliver_canonical(rows, before_attempt: -> { raise StandardError, "heartbeat boom" })
    end
  end

  test "a raising before_attempt hook still routes to DLQ and emits metric on total failure" do
    rows = [sample_row(event_id: "hb-raise-2")]
    captured = []
    metric_stub = lambda do |name, _value, tags: {}|
      captured << [name, tags]
    end

    Grovs::Metrics.stub(:histogram, metric_stub) do
      ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { raise StandardError, "always fails" }) do
        assert_not ClickhouseWriteService.deliver_canonical(rows, before_attempt: -> { raise StandardError, "heartbeat boom" })
      end
    end

    assert_equal 1, REDIS.with { |c| c.llen(DLQ_KEY) }, "batch must still land in DLQ when the heartbeat hook raises"
    dlq_metric = captured.find { |name, tags| name == "clickhouse.canonical.delivery_ms" && tags[:status] == "dlq" }
    assert dlq_metric, "must still emit the dlq delivery metric when the heartbeat hook raises"
  end

  # --- HIGH-3a: route_to_dlq is resilient to non-Redis failures ---

  test "route_to_dlq logs and does not escape when formatting raises" do
    rows = [sample_row(event_id: "fmt-1")]

    # Force the bounded retries to fail so we fall into route_to_dlq, then make
    # format_timestamps (called inside route_to_dlq) raise a non-Redis error.
    ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { raise StandardError, "always fails" }) do
      ClickhouseWriteService.stub(:format_timestamps, ->(_r) { raise ArgumentError, "bad timestamp" }) do
        assert_nothing_raised do
          assert_not ClickhouseWriteService.deliver_canonical(rows)
        end
      end
    end
  end

  # --- HIGH-3b: malformed DLQ entry is skipped, drain continues ---

  test "drain skips a malformed DLQ entry and continues draining good entries" do
    skip_unless_clickhouse!
    pid = 778_804
    good = { rows: [sample_row(event_id: "drain-good", project_id: pid)].map { |r| ClickhouseWriteService.send(:format_timestamps, r) } }.to_json

    # Park a malformed entry (not valid JSON) ahead of a good one. rpop reads
    # from the tail, so push good first (tail), then malformed (head) — malformed
    # is popped first and must not halt the drain.
    REDIS.with do |c|
      c.lpush(DLQ_KEY, good)
      c.lpush(DLQ_KEY, "this-is-not-json{")
    end

    drained = ClickhouseWriteService.drain_canonical_dlq
    assert_equal 1, drained, "the good entry must still drain past the malformed one"
    assert_equal 0, REDIS.with { |c| c.llen(DLQ_KEY) }, "malformed entry must be dropped, not re-parked forever"

    post = Clickhouse.with { |conn| conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{pid}") }
    assert_equal 1, post, "good drained row must land in canonical"
  end

  # --- MEDIUM: delivery metric tags + dlq counter ---

  test "delivery metric carries status ok and attempt count on success" do
    rows = [sample_row(event_id: "tags-ok")]
    captured = []
    Grovs::Metrics.stub(:histogram, ->(name, _v, tags: {}) { captured << [name, tags] }) do
      ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { true }) do
        assert ClickhouseWriteService.deliver_canonical(rows)
      end
    end

    name, tags = captured.find { |n, _| n == "clickhouse.canonical.delivery_ms" }
    assert_equal "clickhouse.canonical.delivery_ms", name
    assert_equal "ok", tags[:status]
    assert_equal 1, tags[:attempts]
  end

  test "delivery metric carries status dlq and max attempts on failure" do
    rows = [sample_row(event_id: "tags-dlq")]
    captured = []
    Grovs::Metrics.stub(:histogram, ->(name, _v, tags: {}) { captured << [name, tags] }) do
      ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { raise StandardError, "always fails" }) do
        assert_not ClickhouseWriteService.deliver_canonical(rows)
      end
    end

    _name, tags = captured.find { |n, _| n == "clickhouse.canonical.delivery_ms" }
    assert_equal "dlq", tags[:status]
    assert_equal ClickhouseWriteService::CANONICAL_MAX_ATTEMPTS, tags[:attempts]
  end

  test "dlq counter increments by the row count on total failure, tagged by table" do
    rows = [sample_row(event_id: "cnt-1"), sample_row(event_id: "cnt-2"), sample_row(event_id: "cnt-3")]
    captured = []
    Grovs::Metrics.stub(:increment, ->(name, by: 1, **kw) { captured << [name, by, kw[:tags]] }) do
      ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { raise StandardError, "always fails" }) do
        assert_not ClickhouseWriteService.deliver_canonical(rows)
      end
    end

    dlq_counter = captured.find { |name, _, _| name == "clickhouse.dlq" }
    assert dlq_counter, "must emit the generalized dlq counter"
    assert_equal 3, dlq_counter[1], "dlq counter must increment by the row count"
    assert_equal "events", dlq_counter[2][:table], "dlq counter must be tagged with the table"
  end

  test "delivery still succeeds when emit_delivery_metric raises" do
    rows = [sample_row(event_id: "metric-boom")]
    Grovs::Metrics.stub(:histogram, ->(*) { raise StandardError, "metrics down" }) do
      ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { true }) do
        assert_nothing_raised do
          assert ClickhouseWriteService.deliver_canonical(rows)
        end
      end
    end
  end
end
