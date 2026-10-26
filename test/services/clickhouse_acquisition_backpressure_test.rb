# frozen_string_literal: true

require "test_helper"

class ClickhouseAcquisitionBackpressureTest < ActiveSupport::TestCase
  setup do
    REDIS.with { |c| c.del(*slot_keys, service.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(*slot_keys, service.dirty_key) }
  end

  test "concurrent repairs stop at the shared limit and leave skipped history dirty" do
    entered = Queue.new
    release = Queue.new
    workers = []
    conn = Object.new
    conn.define_singleton_method(:execute) do |_sql|
      entered << true
      release.pop
    end

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(conn) }) do
        begin
          workers = Array.new(service::ACQUISITION_REPAIR_CONCURRENCY) do
            Thread.new { service.rebuild_acquisition("202601", project_id: 7, raw_visitor_ids: [10]) }
          end
          Timeout.timeout(5) { workers.size.times { entered.pop } }

          assert_not service.rebuild_acquisition("202602", project_id: 8, raw_visitor_ids: [20])
          assert_includes service.dirty_partitions, "202602"
        ensure
          workers.size.times { release << true }
          workers.each(&:value)
        end

        release << true
        assert service.rebuild_acquisition("202602", project_id: 8, raw_visitor_ids: [20])
      end
    end
    assert slot_keys.none? { |key| REDIS.exists?(key) }
  end

  test "server failure frees the repair slot" do
    conn = Object.new
    conn.define_singleton_method(:execute) { |_| raise ClickHouse::Client::DatabaseError, "Code: 241" }

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(conn) }) do
        assert_raises(ClickHouse::Client::DatabaseError) do
          service.rebuild_acquisition("202601", project_id: 7, raw_visitor_ids: [10])
        end
      end
    end

    assert slot_keys.none? { |key| REDIS.exists?(key) }
  end

  test "transport failure retains the lease while the server query may still run" do
    conn = Object.new
    conn.define_singleton_method(:execute) { |_| raise Net::ReadTimeout }

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(conn) }) do
        assert_raises(Net::ReadTimeout) do
          service.rebuild_acquisition("202601", project_id: 7, raw_visitor_ids: [10])
        end
      end
    end

    assert_operator REDIS.ttl(slot_keys.first), :>, service::ACQUISITION_MAX_EXECUTION_SECONDS
  end

  test "acquisition HTTP deadlines exceed server deadlines and restore the caller deadline" do
    budgets = []
    sqls = []
    conn = Object.new
    conn.define_singleton_method(:execute) do |sql|
      budgets << Thread.current[:clickhouse_read_timeout_override]
      sqls << sql.to_sql
    end

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(conn) }) do
        Clickhouse.with_request_timeout(7) do
          service.rebuild_acquisition("202601", project_id: 7, raw_visitor_ids: [10])
          service.rebuild_acquisition("202601")
          assert_equal 7, Thread.current[:clickhouse_read_timeout_override]
        end
      end
    end

    assert_equal [15, service::ACQUISITION_MAX_EXECUTION_SECONDS + 30], budgets
    assert_includes sqls.first, "max_threads = 1"
    assert_includes sqls.first, "FROM visitor_acquisition AS a"
    assert_not_includes sqls.first, "FROM events"
    assert_includes sqls.last, "max_threads = #{service::REBUILD_MAX_THREADS}"
  end

  test "expired repair holder cannot release a successor lease" do
    conn = Object.new
    key = slot_keys.first
    conn.define_singleton_method(:execute) { |_| REDIS.set(key, "successor", ex: 60) }

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(conn) }) do
        service.rebuild_acquisition("202601", project_id: 7, raw_visitor_ids: [10])
      end
    end

    assert_equal "successor", REDIS.get(key)
  end

  test "catchup retains dirty history when acquisition rebuild is lock skipped" do
    lock_key = service.lock_key_for(:acquisition, "202601")
    REDIS.set(lock_key, "held", ex: 60)
    service.mark_dirty(Date.new(2026, 1, 1))

    travel_to Time.utc(2026, 9, 9) do
      Clickhouse.stub(:enabled?, true) do
        service.stub(:rebuild_partition, ->(*) { true }) do
          service.rebuild_stale_dirty
        end
      end
    end

    assert_includes service.dirty_partitions, "202601"
  ensure
    REDIS.del(lock_key)
  end

  [[], %w[202401 202402 202601 202606]].each do |partitions|
    test "merge entry folds once with #{partitions.size} discovered months" do
      queries = []
      conn = Object.new
      conn.define_singleton_method(:execute) { |query| queries << query.to_sql }
      Clickhouse.stub(:enabled?, true) do
        service.stub(:acquisition_repair_visitor_ids, ->(*) { [10, 20] }) do
          service.stub(:visitor_partitions, ->(*) { partitions }) do
            Clickhouse.stub(:with, ->(&block) { block.call(conn) }) do
              assert_equal partitions, service.repair_acquisition_for_visitor_merge(7, 10, 20)
            end
          end
        end
      end
      assert_equal 1, queries.size
      assert_includes queries.first, "FROM visitor_acquisition AS a"
    end
  end

  test "a busy merge retains every discovered month" do
    slot_keys.each { |key| REDIS.set(key, "held", ex: 60) }
    partitions = %w[202401 202402 202601 202606]
    Clickhouse.stub(:enabled?, true) do
      service.stub(:acquisition_repair_visitor_ids, ->(*) { [10, 20] }) do
        service.stub(:visitor_partitions, ->(*) { partitions }) do
          assert_not service.repair_acquisition_for_visitor_merge(7, 10, 20)
        end
      end
    end
    assert_equal partitions, service.dirty_partitions.sort
  end

  test "oversized merge sheds without taking a slot or raising and keeps every discovered month" do
    partitions = %w[202401 202402]
    Clickhouse.stub(:enabled?, true) do
      service.stub(:acquisition_repair_visitor_ids, ->(*) { (1..Clickhouse::MAX_IN_LIST_IDS + 1).to_a }) do
        service.stub(:visitor_partitions, ->(*) { partitions }) do
          assert_not service.repair_acquisition_for_visitor_merge(7, 10, 20)
        end
      end
    end
    assert_equal partitions, service.dirty_partitions.sort
    assert slot_keys.none? { |key| REDIS.exists?(key) }
  end

  private

  def service
    ClickhouseRollupRebuildService
  end

  def slot_keys
    Array.new(service::ACQUISITION_REPAIR_CONCURRENCY) do |i|
      "#{service::LOCK_PREFIX}:#{Clickhouse.default_database}:acquisition_repair_slot:#{i}"
    end
  end
end
