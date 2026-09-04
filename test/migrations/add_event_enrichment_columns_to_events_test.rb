# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260424113715_add_event_enrichment_columns_to_events")

# Unit tests for the lock-timeout retry logic. Stubs execute/sleep so no real
# ClickHouse/PG lock is needed — pure control-flow verification.
class AddEventEnrichmentColumnsToEventsTest < ActiveSupport::TestCase
  setup { @migration = AddEventEnrichmentColumnsToEvents.new }

  test "retries on LockWaitTimeout and succeeds once the lock is free" do
    calls = 0
    with_stubs do
      @migration.send(:with_lock_timeout_retries) do
        calls += 1
        raise ActiveRecord::LockWaitTimeout if calls < 3
      end
    end
    assert_equal 3, calls, "should keep retrying until the block succeeds"
  end

  test "gives up and re-raises after MAX_LOCK_RETRIES" do
    calls = 0
    assert_raises(ActiveRecord::LockWaitTimeout) do
      with_stubs do
        @migration.send(:with_lock_timeout_retries) do
          calls += 1
          raise ActiveRecord::LockWaitTimeout
        end
      end
    end
    assert_equal AddEventEnrichmentColumnsToEvents::MAX_LOCK_RETRIES + 1, calls,
                 "initial attempt plus MAX_LOCK_RETRIES retries"
  end

  test "always resets lock_timeout, even when it gives up" do
    executed = []
    @migration.stub(:sleep, nil) do
      @migration.stub(:execute, ->(sql) { executed << sql }) do
        assert_raises(ActiveRecord::LockWaitTimeout) do
          @migration.send(:with_lock_timeout_retries) { raise ActiveRecord::LockWaitTimeout }
        end
      end
    end
    assert_includes executed, "SET lock_timeout = DEFAULT"
  end

  private

  def with_stubs(&block)
    @migration.stub(:sleep, nil) do
      @migration.stub(:execute, nil, &block)
    end
  end
end
