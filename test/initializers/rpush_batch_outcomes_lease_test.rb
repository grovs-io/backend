require "test_helper"

class RpushBatchOutcomesLeaseTest < ActiveSupport::TestCase
  self.use_transactional_tests = false # transactional tests share one connection across threads and hide leases

  def leased_after(&)
    Thread.new do
      yield
      ActiveRecord::Base.connection_pool.active_connection?
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end.value
  end

  test "a plain with_connection that calls .connection leaves the thread holding a lease (why borrow exists)" do
    assert leased_after { ActiveRecord::Base.connection_pool.with_connection { ActiveRecord::Base.connection.select_value("SELECT 1") } }
  end

  test "recording a batch leaves no connection leased to the dispatcher thread" do
    batch = Rpush::Daemon::Batch.new([])
    assert_not leased_after { batch.send(:borrow) { ActiveRecord::Base.connection.select_value("SELECT 1") } }
  end
end
