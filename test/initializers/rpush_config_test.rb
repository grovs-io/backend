require "test_helper"
require "rpush/daemon"

class RpushConfigTest < ActiveSupport::TestCase
  include ConstStubHelper
  test "the daemon polls four times a second for 1000 rows and the sync timer only starts for the rpush role" do
    assert_equal 1000, Rpush.config.batch_size
    assert_equal 0.25, Rpush.config.push_poll
    assert_nil RpushAppSync.thread, "no sync thread outside the rpush role"
  end

  test "tick syncs the daemon's apps and swallows a failure" do
    calls = 0
    Rpush::Daemon::Synchronizer.stub(:sync, -> { calls += 1 }) { RpushAppSync.tick }
    assert_equal 1, calls
    Rpush::Daemon::Synchronizer.stub(:sync, -> { raise "boom" }) { assert_nothing_raised { RpushAppSync.tick } }
  end

  test "start spawns the timer thread and stop clears it" do
    RpushAppSync.start(interval: 3600)
    assert RpushAppSync.thread.alive?
  ensure
    RpushAppSync.stop
    assert_nil RpushAppSync.thread
  end

  test "a completed batch records its outcomes in one call per outcome group" do
    delivered = Array.new(3) { |i| Rpush::Fcm::Notification.new(id: i + 1) }
    failed = Array.new(2) { |i| Rpush::Fcm::Notification.new(id: i + 10) }
    batch = Rpush::Daemon::Batch.new(delivered + failed)
    calls = []
    store_methods = %i[mark_delivered mark_failed mark_batch_delivered mark_batch_failed mark_batch_retryable]
    store = Class.new { store_methods.each { |m| define_method(m) { |*| nil } } }.new

    Rpush::Daemon.stub(:store, store) do
      PushOutcomes.stub(:delivered_batch, ->(ns) { calls << [:delivered, ns.map(&:id)] }) do
        PushOutcomes.stub(:failed_batch, ->(ns, code, desc) { calls << [:failed, ns.map(&:id), code, desc] }) do
          delivered.each { |n| batch.mark_delivered(n) }
          failed.each { |n| batch.mark_failed(n, 410, "Unregistered") }
          (delivered + failed).size.times { batch.notification_processed }
        end
      end
    end

    assert_equal [[:delivered, [1, 2, 3]], [:failed, [10, 11], 410, "Unregistered"]], calls
  end

  test "FCM failures that differ only by notification id share one outcome group" do
    failed = Array.new(3) { |i| Rpush::Fcm::Notification.new(id: i + 1) }
    batch = Rpush::Daemon::Batch.new(failed)
    groups = []
    store = Class.new { %i[mark_failed mark_batch_failed].each { |m| define_method(m) { |*| nil } } }.new

    Rpush::Daemon.stub(:store, store) do
      PushOutcomes.stub(:failed_batch, ->(ns, code, desc) { groups << [ns.map(&:id), code, desc] }) do
        failed.each { |n| batch.mark_failed(n, 404, "Unable to deliver notification #{n.id}, received error 404 (Client was not registered)") }
        batch.all_processed
      end
    end

    assert_equal [[[1, 2, 3], 404, "received error 404 (Client was not registered)"]], groups
    assert PushDelivery.dead_token_error?(404, groups.first.last) if defined?(PushDelivery)
  end

  test "no per-notification reflection is left to double-count" do
    %i[notification_delivered notification_failed].each do |name|
      assert_not Rpush.reflection_stack.any? { |c| c.instance_variable_get(:@reflections).key?(name) }, "#{name} is registered"
    end
  end

  test "a busy pool is waited out without tearing down every connection" do
    store = Rpush::Daemon::Store::ActiveRecord.new
    attempts = 0
    busy_then_free = lambda do |&blk|
      attempts += 1
      raise ActiveRecord::ConnectionTimeoutError, "all pooled connections were in use" if attempts == 1

      blk.call
    end
    store.stub(:database_connection_lost, -> { flunk "a busy pool is not a lost connection" }) do
      with_const(RpushDatabaseRetry, :POOL_BUSY_PAUSE, 0) do
        ActiveRecord::Base.connection_pool.stub(:with_connection, busy_then_free) do
          assert_equal :done, store.with_database_reconnect_and_retry { :done }
        end
      end
    end
    assert_equal 2, attempts
  end

  test "notifications of a deleted app are skipped instead of stranding the rest of the fetch" do
    Rpush::Daemon.stub(:store, Rpush::Daemon::Store::ActiveRecord.new) do
      assert_nothing_raised { Rpush::Daemon::AppRunner.start_app_with_id(-1) }
    end
  end

  test "a statement error is retried without tearing down every connection" do
    store = Rpush::Daemon::Store::ActiveRecord.new
    attempts = 0
    store.stub(:sleep_to_avoid_thrashing, nil) do
      store.stub(:database_connection_lost, -> { flunk "a deadlock is not a lost connection" }) do
        result = store.with_database_reconnect_and_retry do
          attempts += 1
          raise ActiveRecord::Deadlocked, "deadlock detected" if attempts == 1

          :done
        end
        assert_equal :done, result
      end
    end
  end

  test "a lost connection reconnects through the Rails 8 connection handler" do
    cleared = established = false
    ActiveRecord::Base.connection_handler.stub(:clear_all_connections!, ->(*) { cleared = true }) do
      ActiveRecord::Base.stub(:establish_connection, ->(*) { established = true }) do
        Rpush::Daemon::Store::ActiveRecord.new.send(:reconnect_database)
      end
    end
    assert cleared && established
  end

  test "a stopping daemon hands back the pushes it fetched but never started, and finishes a half-sent batch" do
    apns = Rpush::Apnsp8::App.create!(name: "stop", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    fcm = Rpush::Fcm::App.create!(name: "stop-f", firebase_project_id: "p", json_key: "{}", connections: 1)
    queued = Array.new(2) { |i| Rpush::Apnsp8::Notification.create!(app: apns, device_token: i.to_s * 64, alert: "x", processing: true) }
    sent, unsent = Array.new(2) { |i| Rpush::Fcm::Notification.create!(app: fcm, device_token: "f#{i}", processing: true) }
    other = Rpush::Apnsp8::Notification.create!(app: apns, device_token: "9" * 64, alert: "x", processing: true)

    Rpush::Daemon.stub(:store, Rpush::Daemon::Store::ActiveRecord.new) do
      apns_runner = Rpush::Daemon::AppRunner.new(apns)
      apns_runner.send(:queue).push(Rpush::Daemon::QueuePayload.new(Rpush::Daemon::Batch.new(queued)))
      fcm_runner = Rpush::Daemon::AppRunner.new(fcm)
      fcm_batch = Rpush::Daemon::Batch.new([sent, unsent])
      fcm_runner.send(:queue).push(Rpush::Daemon::QueuePayload.new(fcm_batch, unsent))
      fcm_batch.mark_delivered(sent)
      fcm_batch.notification_processed

      apns_runner.stop
      fcm_runner.stop
      assert fcm_batch.complete?, "the dropped push counts as processed so the sent one is recorded"
    end

    assert_equal [false, false], queued.map { |n| n.reload.processing }
    assert_not unsent.reload.processing
    assert sent.reload.delivered
    assert other.reload.processing, "a push this daemon never fetched is not its to release"
  ensure
    Rpush::Notification.delete_all
    Rpush::App.delete_all
  end

  test "rows a dead daemon left in processing go back to the queue after an hour, or at boot; live ones stay" do
    app = Rpush::Apnsp8::App.create!(name: "stale", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    stale = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x", processing: true)
    live = Rpush::Apnsp8::Notification.create!(app: app, device_token: "b" * 64, alert: "x", processing: true)
    stale.update_columns(updated_at: 61.minutes.ago)

    assert_equal 1, RpushStaleProcessing.release!
    assert_not stale.reload.processing
    assert live.reload.processing
    RpushAppSync.release_on_boot
    assert live.reload.processing, "a deploy overlaps the old daemon, so boot leaves its fresh claims alone"
    live.update_columns(updated_at: 6.minutes.ago)
    RpushAppSync.release_on_boot
    assert_not live.reload.processing
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end
end
